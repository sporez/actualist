import Foundation
import Observation

struct WalletImportDisplayedCandidate: Identifiable, Equatable, Sendable {
    var id: String { candidate.financialID }
    var candidate: WalletTransactionCandidate
    var isDuplicate: Bool
}

@MainActor
@Observable
final class WalletImportViewModel {
    var selectedAccountID: String?
    private(set) var candidates: [WalletTransactionCandidate] = []
    private(set) var existingImportedIDs: Set<String> = []
    private(set) var isImporting = false
    private(set) var result: WalletTransactionImportResult?
    private(set) var errorMessage: String?

    var displayedCandidates: [WalletImportDisplayedCandidate] {
        candidates.map { candidate in
            WalletImportDisplayedCandidate(
                candidate: candidate,
                isDuplicate: existingImportedIDs.contains(candidate.financialID)
            )
        }
    }

    var newCandidates: [WalletTransactionCandidate] {
        candidates.filter { !existingImportedIDs.contains($0.financialID) }
    }

    var canImport: Bool {
        !isImporting && selectedAccountID != nil && !newCandidates.isEmpty
    }

    var importButtonTitle: String {
        let count = newCandidates.count
        return count == 1 ? "Add 1 Transaction" : "Add \(count) Transactions"
    }

    func openAccounts(from appState: AppState) -> [ActualAccount] {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return []
        }
        let accounts = appState.accountRepository
            .accountDisplays(budgetID: budgetID)
            .map(\.account)
            .filter { !$0.closed }
        return appState.orderedAccounts(accounts, budgetID: budgetID)
    }

    func prepare(using appState: AppState) async {
        let accounts = openAccounts(from: appState)
        let preferredID = Self.preferredAccountID(
            defaultAccountID: appState.settings.selectedBudgetID.flatMap {
                appState.defaultAccountID(forBudgetID: $0)
            },
            openAccountIDs: accounts.map(\.id)
        )
        if selectedAccountID == nil || !accounts.contains(where: { $0.id == selectedAccountID }) {
            selectedAccountID = preferredID
        }
        await refreshExistingIDs(using: appState)
    }

    func noteAccountChanged() {
        result = nil
        errorMessage = nil
    }

    func refreshExistingIDs(using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID,
              let accountID = selectedAccountID else {
            existingImportedIDs = []
            return
        }
        do {
            existingImportedIDs = try await appState.transactionRepository.existingImportedIDs(
                budgetID: budgetID,
                accountID: accountID
            )
        } catch {
            existingImportedIDs = []
            errorMessage = error.localizedDescription
        }
    }

    func updateFields(
        _ fields: [WalletTransactionFields],
        currency: BudgetCurrency = .usd
    ) {
        candidates = fields.compactMap { WalletTransactionMapper.map($0, currency: currency) }
        result = nil
        errorMessage = nil
    }

    func importSelected(using appState: AppState) async {
        guard !isImporting,
              let budgetID = appState.settings.selectedBudgetID,
              let accountID = selectedAccountID,
              !newCandidates.isEmpty else {
            return
        }

        isImporting = true
        errorMessage = nil
        result = nil
        defer { isImporting = false }

        do {
            result = try await appState.transactionRepository.importWalletTransactions(
                newCandidates,
                intoAccountID: accountID,
                budgetID: budgetID
            )
            existingImportedIDs = try await appState.transactionRepository.existingImportedIDs(
                budgetID: budgetID,
                accountID: accountID
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    nonisolated static func preferredAccountID(
        defaultAccountID: String?,
        openAccountIDs: [String]
    ) -> String? {
        if let defaultAccountID, openAccountIDs.contains(defaultAccountID) {
            return defaultAccountID
        }
        return openAccountIDs.first
    }
}
