import Foundation
import Observation

/// Wallet import's device-local account links: budget → FinanceKit account
/// ID → Actual account ID. FinanceKit IDs differ per device, so links never
/// sync. `AppState` stores them in app settings.
@MainActor
protocol WalletAccountLinkStoring: AnyObject {
    func walletAccountLinks(budgetID: String) -> [String: String]
    func setWalletAccountLink(_ accountID: String?, walletAccountID: String, budgetID: String)
}

/// One Wallet account's share of a picker selection.
struct WalletImportGroup: Equatable, Sendable {
    let walletAccountID: String
    var candidates: [WalletTransactionCandidate]
}

/// A remembered link the Bank Sync screen lists.
struct WalletAccountLinkRow: Identifiable, Equatable, Sendable {
    var id: String { walletAccountID }
    let walletAccountID: String
    let accountName: String
}

enum WalletImportPlanning {
    /// Groups in first-seen order. Rows the mapper drops (rejected, zero or
    /// unreadable amounts) are left out.
    static func groups(
        _ fields: [WalletTransactionFields],
        currency: BudgetCurrency
    ) -> [WalletImportGroup] {
        var groups: [WalletImportGroup] = []
        var indexByWalletAccount: [String: Int] = [:]
        for field in fields {
            guard let candidate = WalletTransactionMapper.map(field, currency: currency) else { continue }
            if let index = indexByWalletAccount[field.walletAccountID] {
                groups[index].candidates.append(candidate)
            } else {
                indexByWalletAccount[field.walletAccountID] = groups.count
                groups.append(WalletImportGroup(walletAccountID: field.walletAccountID, candidates: [candidate]))
            }
        }
        return groups
    }

    /// The linked account while it is still open; otherwise the user is asked again.
    static func linkedAccountID(
        for walletAccountID: String,
        links: [String: String],
        openAccountIDs: [String]
    ) -> String? {
        guard let accountID = links[walletAccountID], openAccountIDs.contains(accountID) else {
            return nil
        }
        return accountID
    }

    static func suggestedAccountID(defaultAccountID: String?, openAccountIDs: [String]) -> String? {
        if let defaultAccountID, openAccountIDs.contains(defaultAccountID) {
            return defaultAccountID
        }
        return openAccountIDs.first
    }

    /// Links whose account still exists, by account name.
    static func linkRows(
        links: [String: String],
        accountNames: [String: String]
    ) -> [WalletAccountLinkRow] {
        links.compactMap { walletAccountID, accountID in
            accountNames[accountID].map {
                WalletAccountLinkRow(walletAccountID: walletAccountID, accountName: $0)
            }
        }
        .sorted { ($0.accountName, $0.walletAccountID) < ($1.accountName, $1.walletAccountID) }
    }
}

extension WalletTransactionImportResult {
    static let empty = WalletTransactionImportResult(addedCount: 0, matchedCount: 0)

    func adding(_ other: WalletTransactionImportResult) -> WalletTransactionImportResult {
        WalletTransactionImportResult(
            addedCount: addedCount + other.addedCount,
            matchedCount: matchedCount + other.matchedCount,
            skippedCount: skippedCount + other.skippedCount
        )
    }
}

/// Runs a Wallet picker selection the way Bank Sync runs a download: no
/// review list. Each Wallet account imports into its remembered account; the
/// first import from an unlinked Wallet account asks once. A new selection,
/// a cancel or a budget switch bumps `generation`, so a late result from an
/// older run is dropped.
@MainActor
@Observable
final class WalletImportCoordinator {
    struct AccountRequest: Equatable {
        let walletAccountID: String
        let transactionCount: Int
        var selectedAccountID: String?
    }

    enum State: Equatable {
        case idle
        case needsAccount(AccountRequest)
        case importing
        case finished(WalletTransactionImportResult)
        /// `partial` is what earlier Wallet accounts in the same selection
        /// already committed.
        case failed(message: String, partial: WalletTransactionImportResult?)
    }

    private struct Run {
        let budgetID: String
        let groups: [WalletImportGroup]
        var resolved: [String: String]
        let suggestedAccountID: String?
    }

    private(set) var state: State = .idle
    private var run: Run?
    private var generation = 0

    var isAskingForAccount: Bool {
        if case .needsAccount = state { return true }
        return false
    }

    func begin(
        _ fields: [WalletTransactionFields],
        currency: BudgetCurrency,
        budgetID: String,
        openAccountIDs: [String],
        defaultAccountID: String?,
        links: any WalletAccountLinkStoring,
        repository: any TransactionRepositoryProtocol
    ) async {
        generation += 1
        let groups = WalletImportPlanning.groups(fields, currency: currency)
        guard !groups.isEmpty else {
            run = nil
            state = .finished(WalletTransactionImportResult(addedCount: 0, matchedCount: 0, skippedCount: fields.count))
            return
        }
        let stored = links.walletAccountLinks(budgetID: budgetID)
        var resolved: [String: String] = [:]
        for group in groups {
            resolved[group.walletAccountID] = WalletImportPlanning.linkedAccountID(
                for: group.walletAccountID,
                links: stored,
                openAccountIDs: openAccountIDs
            )
        }
        run = Run(
            budgetID: budgetID,
            groups: groups,
            resolved: resolved,
            suggestedAccountID: WalletImportPlanning.suggestedAccountID(
                defaultAccountID: defaultAccountID,
                openAccountIDs: openAccountIDs
            )
        )
        await advance(repository: repository)
    }

    func selectAccount(_ accountID: String?) {
        guard case .needsAccount(var request) = state else { return }
        request.selectedAccountID = accountID
        state = .needsAccount(request)
    }

    func confirmAccount(
        links: any WalletAccountLinkStoring,
        repository: any TransactionRepositoryProtocol
    ) async {
        guard case .needsAccount(let request) = state,
              let accountID = request.selectedAccountID,
              var run else {
            return
        }
        links.setWalletAccountLink(accountID, walletAccountID: request.walletAccountID, budgetID: run.budgetID)
        run.resolved[request.walletAccountID] = accountID
        self.run = run
        await advance(repository: repository)
    }

    /// Dismissing the account question imports nothing.
    func cancel() {
        generation += 1
        run = nil
        state = .idle
    }

    func forgetLink(_ walletAccountID: String, budgetID: String, links: any WalletAccountLinkStoring) {
        links.setWalletAccountLink(nil, walletAccountID: walletAccountID, budgetID: budgetID)
    }

    private func advance(repository: any TransactionRepositoryProtocol) async {
        guard let run else { return }
        if let unresolved = run.groups.first(where: { run.resolved[$0.walletAccountID] == nil }) {
            state = .needsAccount(AccountRequest(
                walletAccountID: unresolved.walletAccountID,
                transactionCount: unresolved.candidates.count,
                selectedAccountID: run.suggestedAccountID
            ))
            return
        }
        self.run = nil
        await perform(run, repository: repository)
    }

    private func perform(_ run: Run, repository: any TransactionRepositoryProtocol) async {
        let generation = self.generation
        state = .importing
        var total = WalletTransactionImportResult.empty
        for group in run.groups {
            guard let accountID = run.resolved[group.walletAccountID] else { continue }
            do {
                let result = try await repository.importWalletTransactions(
                    group.candidates,
                    intoAccountID: accountID,
                    budgetID: run.budgetID
                )
                total = total.adding(result)
            } catch {
                guard generation == self.generation else { return }
                state = error.isCancellation
                    ? .idle
                    : .failed(
                        message: error.userFacingMessage ?? "Apple Wallet activity could not be added.",
                        partial: total == .empty ? nil : total
                    )
                return
            }
            guard generation == self.generation else { return }
        }
        state = .finished(total)
    }
}

extension AppState: WalletAccountLinkStoring {}

extension WalletImportCoordinator {
    static func openAccounts(from appState: AppState) -> [ActualAccount] {
        guard let budgetID = appState.settings.selectedBudgetID else { return [] }
        let accounts = appState.accountRepository
            .accountDisplays(budgetID: budgetID)
            .map(\.account)
            .filter { !$0.closed }
        return appState.orderedAccounts(accounts, budgetID: budgetID)
    }

    static func linkRows(from appState: AppState) -> [WalletAccountLinkRow] {
        guard let budgetID = appState.settings.selectedBudgetID else { return [] }
        let names = Dictionary(
            appState.accountRepository.accountDisplays(budgetID: budgetID).map { ($0.account.id, $0.account.name) },
            uniquingKeysWith: { first, _ in first }
        )
        return WalletImportPlanning.linkRows(links: appState.walletAccountLinks(budgetID: budgetID), accountNames: names)
    }

    func begin(_ fields: [WalletTransactionFields], appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else { return }
        await begin(
            fields,
            currency: appState.localFirstStore.budgetCurrency(budgetID: budgetID),
            budgetID: budgetID,
            openAccountIDs: Self.openAccounts(from: appState).map(\.id),
            defaultAccountID: appState.defaultAccountID(forBudgetID: budgetID),
            links: appState,
            repository: appState.transactionRepository
        )
    }

    func confirmAccount(appState: AppState) async {
        await confirmAccount(links: appState, repository: appState.transactionRepository)
    }

    func forgetLink(_ walletAccountID: String, appState: AppState) {
        guard let budgetID = appState.settings.selectedBudgetID else { return }
        forgetLink(walletAccountID, budgetID: budgetID, links: appState)
    }
}
