import Foundation
import Observation

/// Owns one-tap download/apply coordination and Bank Sync display state.
@MainActor
@Observable
final class BankSyncViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case downloading
        case applying
        case failed(String)
    }

    /// Remote SimpleFIN accounts are for the link sheet only. Sync All must
    /// not wait on this list.
    enum RemoteAccountsStatus: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// One account line on the screen, pre-formatted for display.
    struct AccountLine: Identifiable, Equatable {
        let id: String
        let name: String
        let isLinked: Bool
        let isSyncable: Bool
        /// SimpleFIN-side account id when linked.
        let remoteAccountID: String?
        let lastSyncText: String
        let statusText: String?
        let statusColorKind: StatusColorKind

        enum StatusColorKind {
            case none, healthy, pending, failed
        }
    }

    struct ReviewMatchLine: Identifiable, Equatable {
        let id: String
        let title: String
        let dateText: String
        let amountText: String
        let changes: [String]
    }

    /// Completed or blocked account outcome, never uncommitted proposed counts.
    struct ResultLine: Identifiable, Equatable {
        let id: String
        let accountName: String
        let addedCount: Int
        let updatedCount: Int
        let matchLines: [ReviewMatchLine]
        let unchangedCount: Int
        let problemCount: Int
        let problemSummary: String?
        let statusText: String?
        let openingBalanceText: String?
    }

    private(set) var phase: Phase = .idle
    private(set) var serverSupport: SimpleFINServerSupport?
    /// A device-claimed SimpleFIN access key exists (Phase 5). Used as the
    /// provider only when the server cannot serve SimpleFIN itself.
    private(set) var hasDeviceKey = false
    private(set) var isClaiming = false
    /// Pasted setup token draft. Presentation-only; the store claims it and
    /// stores only the derived access key in the Keychain.
    var draftSetupToken = ""
    private(set) var accountLines: [AccountLine] = []
    private(set) var remoteAccounts: [SimpleFINRemoteAccount] = []
    private(set) var remoteAccountsStatus: RemoteAccountsStatus = .idle
    private(set) var resultLines: [ResultLine] = []
    private(set) var selectedAccountID: String?
    /// Last finished run on this device, persisted per budget. Its summary
    /// includes completed work even when a later account fails.
    private(set) var lastRun: BankSyncLastRun?

    var lastRunCaption: String? {
        lastRun.map { BankSyncCopy.lastRunCaption($0, now: Date()) }
    }

    var isSyncing: Bool { phase == .downloading || phase == .applying }

    var canSyncAll: Bool {
        providerAvailable
            && accountLines.contains { $0.isSyncable }
            && (phase == .ready || isFailed)
            && sessionIsCurrent
            && !isDemoMode
            && !isClaiming
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var canLinkAccounts: Bool {
        providerAvailable && !isSyncing && sessionIsCurrent
    }

    var canClaimDeviceToken: Bool {
        !isClaiming
            && !isSyncing
            && sessionIsCurrent
            && !draftSetupToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var providerAvailable: Bool {
        // SimpleFIN is the only initiate path. Other linked providers stay
        // visible but not syncable (`BankSyncLinkEligibility`). A later
        // provider ORs its own capability here and caches under its own
        // `BankSyncProviderKind`.
        serverSupport == .configured || hasDeviceKey
    }

    var syncButtonTitle: String {
        switch phase {
        case .downloading: "Downloading…"
        case .applying: "Applying…"
        default: "Sync All"
        }
    }

    private let store: LocalFirstActualStore
    private let budgetID: String
    private let currency: BudgetCurrency
    private let isDemoMode: Bool
    private let sessionGeneration: Int
    private var loadGeneration = 0

    private var sessionIsCurrent: Bool {
        store.budgetSessionGeneration == sessionGeneration && store.isOpen(budgetID: budgetID)
    }

    init(
        store: LocalFirstActualStore,
        budgetID: String,
        currency: BudgetCurrency,
        isDemoMode: Bool = false
    ) {
        self.store = store
        self.budgetID = budgetID
        self.currency = currency
        self.isDemoMode = isDemoMode
        self.sessionGeneration = store.budgetSessionGeneration
    }

    func load() async {
        guard !isSyncing, sessionIsCurrent else { return }
        loadGeneration += 1
        let generation = loadGeneration
        // Do not start in `.loading` when a cached provider can enable Sync
        // All immediately.
        do {
            let rows = try await store.bankSyncAccountRows(budgetID: budgetID)
            // The last-run record is display-only; an unreadable one must not
            // block Sync All.
            let persistedRun = try? await store.bankSyncLastRun(budgetID: budgetID)
            guard sessionIsCurrent, generation == loadGeneration else { return }
            try Task.checkCancellation()
            accountLines = rows.map(\.toLine)
            lastRun = persistedRun
            if isDemoMode {
                serverSupport = nil
                hasDeviceKey = false
                remoteAccounts = []
                remoteAccountsStatus = .idle
                phase = .ready
                return
            }
            // Read the device key before probing the server: a claimed token
            // must surface even when the server is unreachable or its
            // answer is unreadable (the provider resolution falls back to
            // the device key in exactly that case).
            do {
                hasDeviceKey = try store.hasBankSyncDeviceKey()
            } catch {
                hasDeviceKey = false
                throw error
            }
            applyCachedSession()
            if phase != .ready {
                phase = .loading
            }
            do {
                let support = try await store.bankSyncSupport(budgetID: budgetID)
                guard sessionIsCurrent, generation == loadGeneration else { return }
                try Task.checkCancellation()
                serverSupport = support
                applyCachedRemoteAccounts()
                phase = .ready
            } catch {
                guard sessionIsCurrent, generation == loadGeneration else { return }
                if hasDeviceKey {
                    serverSupport = nil
                    applyCachedRemoteAccounts()
                    phase = .ready
                } else if store.cachedBankSyncSupport() != nil {
                    phase = .ready
                } else {
                    phase = error.userFacingMessage.map(Phase.failed) ?? .ready
                }
            }
        } catch {
            guard sessionIsCurrent, generation == loadGeneration else { return }
            phase = error.userFacingMessage.map(Phase.failed) ?? .ready
        }
    }

    /// Loads SimpleFIN-side accounts for the link sheet. Safe to call while
    /// Sync All is already enabled; cancellation leaves a loading state idle.
    func ensureRemoteAccounts() async {
        guard canLinkAccounts, !isDemoMode else {
            return
        }
        switch remoteAccountsStatus {
        case .ready, .loading:
            return
        case .idle, .failed:
            break
        }
        if applyCachedRemoteAccounts() {
            return
        }
        remoteAccountsStatus = .loading
        let generation = loadGeneration
        do {
            let accounts = try await store.bankSyncRemoteAccounts(budgetID: budgetID)
            guard sessionIsCurrent, generation == loadGeneration else { return }
            try Task.checkCancellation()
            remoteAccounts = accounts
            remoteAccountsStatus = .ready
        } catch where error.isCancellation {
            guard sessionIsCurrent, generation == loadGeneration else { return }
            if case .loading = remoteAccountsStatus {
                remoteAccountsStatus = .idle
            }
        } catch {
            guard sessionIsCurrent, generation == loadGeneration else { return }
            remoteAccountsStatus = error.userFacingMessage.map(RemoteAccountsStatus.failed) ?? .idle
        }
    }

    private func applyCachedSession() {
        if let cached = store.cachedBankSyncSupport() {
            serverSupport = cached
            phase = .ready
        }
        _ = applyCachedRemoteAccounts()
    }

    @discardableResult
    private func applyCachedRemoteAccounts() -> Bool {
        if let remotes = store.cachedBankSyncRemoteAccounts() {
            remoteAccounts = remotes
            remoteAccountsStatus = .ready
            return true
        }
        remoteAccounts = []
        remoteAccountsStatus = .idle
        return false
    }

    /// Preflight the whole download before the first write, as the background
    /// path does. Each account still commits through the store's guarded writer.
    func syncAll() async {
        guard canSyncAll else { return }
        loadGeneration += 1
        phase = .downloading
        lastRun = nil
        resultLines = []
        let syncableAccountIDs = accountLines.filter(\.isSyncable).map(\.id)
        var tally = BankSyncRunTally()
        var applyingAccountName: String?
        do {
            let plans = try await store.downloadBankSyncPlans(
                accountIDs: syncableAccountIDs,
                budgetID: budgetID
            )
            guard sessionIsCurrent else { return }
            try Task.checkCancellation()
            guard !plans.isEmpty else {
                phase = .failed("Nothing to sync.")
                return
            }
            guard plans.allSatisfy(\.problems.isEmpty) else {
                resultLines = plans.map {
                    $0.toLine(accountNames: accountNames, currency: currency, applied: false)
                }
                await recordRun(BankSyncRunTally.nothingSavedSummary)
                phase = .failed("Nothing was saved. Some bank transactions could not be read; see the account details below.")
                return
            }
            phase = .applying
            for plan in plans {
                guard sessionIsCurrent else { return }
                try Task.checkCancellation()
                applyingAccountName = accountNames[plan.link.accountID] ?? "Account"
                let result: BankSyncReview.ApplyResult
                var refreshFailure: BankSyncCommittedRefreshError?
                do {
                    result = try await store.applyBankSyncPlan(plan, budgetID: budgetID)
                } catch let error as BankSyncCommittedRefreshError {
                    result = error.result
                    refreshFailure = error
                }
                guard sessionIsCurrent else { return }
                tally.record(result, skipped: plan.durableStatus != .ok)
                resultLines.append(plan.toLine(accountNames: accountNames, currency: currency, applied: true))
                if let refreshFailure { throw refreshFailure }
            }
            await recordRun(tally.completedSummary(plannedCount: plans.count))
            phase = .ready
        } catch {
            guard sessionIsCurrent else { return }
            await recordRun(
                tally.stoppedSummary(totalCount: syncableAccountIDs.count)
                    ?? (error.isCancellation ? nil : BankSyncRunTally.nothingSavedSummary)
            )
            phase = error.userFacingMessage.map { message in
                .failed((applyingAccountName.map { "\($0): " } ?? "") + message)
            } ?? .ready
        }
        // Refresh status without a new capability request or reopening the run.
        // Keep the active phase until this read finishes to reject repeated taps.
        let outcome = phase
        phase = .applying
        do {
            let rows = try await store.bankSyncAccountRows(budgetID: budgetID)
            guard sessionIsCurrent else { return }
            accountLines = rows.map(\.toLine)
        } catch {
            // The run outcome remains authoritative if the status read fails.
        }
        guard sessionIsCurrent else { return }
        phase = outcome
    }

    /// Publishes the run immediately and persists it for later visits. Call
    /// while the phase still rejects Sync All. The record is display-only, so
    /// a failed save keeps the run's own outcome.
    private func recordRun(_ summary: String?) async {
        guard let summary, sessionIsCurrent else { return }
        let run = BankSyncLastRun(finishedAt: Date(), trigger: .manual, summary: summary)
        lastRun = run
        try? await store.recordBankSyncLastRun(run, budgetID: budgetID)
    }

    // MARK: - Device token (Phase 5)

    /// Claims the pasted setup token once and stores the derived access key
    /// in the Keychain. The token draft is cleared either way on success.
    func claimDeviceToken() async {
        guard canClaimDeviceToken else {
            return
        }
        isClaiming = true
        defer { isClaiming = false }
        do {
            try await store.claimBankSyncDeviceToken(draftSetupToken)
            draftSetupToken = ""
            await load()
        } catch {
            phase = error.userFacingMessage.map(Phase.failed) ?? .ready
        }
    }

    /// Disconnect forgets the device key only. Links and transactions stay.
    func forgetDeviceKey() async {
        guard !isSyncing, sessionIsCurrent else { return }
        do {
            try store.forgetBankSyncDeviceKey()
            hasDeviceKey = try store.hasBankSyncDeviceKey()
            await load()
        } catch {
            phase = error.userFacingMessage.map(Phase.failed) ?? .ready
        }
    }

    // MARK: - Link / unlink sheet

    func selectAccount(_ id: String) {
        guard !isSyncing else { return }
        selectedAccountID = id
    }

    func dismissAccountSheet() {
        selectedAccountID = nil
    }

    var selectedLine: AccountLine? {
        accountLines.first { $0.id == selectedAccountID }
    }

    /// SimpleFIN's user-facing account name for a linked remote identity.
    /// If fresh remote metadata is unavailable, retain friendly local copy;
    /// the opaque account id is deliberately never a display fallback.
    func linkedAccountDisplayName(for line: AccountLine) -> String {
        guard line.isSyncable,
              let remoteAccountID = line.remoteAccountID,
              let remote = remoteAccounts.first(where: { $0.accountID == remoteAccountID }) else {
            return line.name
        }
        let name = remote.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return name
        }
        if let institution = (remote.institution ?? remote.orgName)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !institution.isEmpty {
            return institution
        }
        return line.name
    }

    /// Remote accounts not already linked to a local account.
    var linkableRemoteAccounts: [SimpleFINRemoteAccount] {
        let linkedRemoteIDs = Set(accountLines.map(\.remoteAccountID).compactMap { $0 })
        return remoteAccounts.filter { !linkedRemoteIDs.contains($0.accountID) }
    }

    func link(selectedRemote remote: SimpleFINRemoteAccount) async {
        guard let accountID = selectedAccountID else {
            return
        }
        do {
            try await store.linkBankAccount(accountID, to: remote, budgetID: budgetID)
            selectedAccountID = nil
            await load()
        } catch {
            phase = error.userFacingMessage.map(Phase.failed) ?? .ready
        }
    }

    func unlinkSelected() async {
        guard let line = selectedLine else {
            return
        }
        guard line.isSyncable else {
            phase = .failed(
                LocalFirstActualStore.BankSyncStoreError.notSimpleFINLinked.localizedDescription
            )
            return
        }
        let accountID = line.id
        do {
            try await store.unlinkBankAccount(accountID, budgetID: budgetID)
            selectedAccountID = nil
            await load()
        } catch {
            phase = error.userFacingMessage.map(Phase.failed) ?? .ready
        }
    }

    private var accountNames: [String: String] {
        Dictionary(uniqueKeysWithValues: accountLines.map { ($0.id, $0.name) })
    }
}

private extension LocalFirstActualStore.BankSyncAccountStatusRow {
    var toLine: BankSyncViewModel.AccountLine {
        BankSyncViewModel.AccountLine(
            id: id,
            name: name,
            isLinked: isLinked,
            isSyncable: isLinked && BankSyncLinkEligibility.isSimpleFIN(syncSource: syncSource),
            remoteAccountID: remoteAccountID,
            lastSyncText: BankSyncCopy.lastSyncText(
                epochMilliseconds: lastSyncEpochMilliseconds,
                isLinked: isLinked
            ),
            statusText: BankSyncCopy.statusText(durableStatus: durableStatus),
            statusColorKind: BankSyncCopy.statusColorKind(
                durableStatus: durableStatus,
                isLinked: isLinked
            )
        )
    }
}

private extension BankSyncReview.AccountPlan {
    func toLine(
        accountNames: [String: String],
        currency: BudgetCurrency,
        applied: Bool
    ) -> BankSyncViewModel.ResultLine {
        BankSyncViewModel.ResultLine(
            id: link.accountID,
            accountName: accountNames[link.accountID] ?? "Account",
            addedCount: applied ? inserts.count + (openingBalance != nil ? 1 : 0) : 0,
            updatedCount: applied ? updates.count : 0,
            matchLines: (applied ? matchDetails : []).map { detail in
                BankSyncViewModel.ReviewMatchLine(
                    id: detail.transactionID,
                    title: detail.currentPayeeName ?? "Transaction",
                    dateText: BankSyncCopy.dayText(detail.dayID),
                    amountText: currency.formatted(detail.amountMinorUnits),
                    changes: detail.changes.map(BankSyncCopy.matchChangeText)
                )
            },
            unchangedCount: applied ? unchangedCount : 0,
            problemCount: problems.count,
            problemSummary: BankSyncCopy.problemSummary(problems),
            statusText: durableStatus == .ok
                ? (applied ? nil : "Not saved")
                : "Skipped · \(BankSyncCopy.statusText(durableStatus: durableStatus.rawValue) ?? "Failed")",
            openingBalanceText: (applied ? openingBalance : nil).map {
                currency.formatted($0.amountMinorUnits)
            }
        )
    }
}
