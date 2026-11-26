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
        /// The provider the link downloads through; nil when unlinked or
        /// linked to a provider Actualist cannot sync (GoCardless and others).
        let provider: BankSyncProviderKind?
        /// Provider-side account id when linked.
        let remoteAccountID: String?
        let lastSyncText: String
        let statusText: String?
        let statusColorKind: StatusColorKind
        /// The account sheet's footer for a linked account.
        let linkedFooterText: String

        /// Linked to a provider Actualist downloads from.
        var isSyncable: Bool { provider != nil }
        /// Only SimpleFIN links are made and removed here; Enable Banking
        /// links belong to the Actual web app.
        var canUnlink: Bool { provider == .simpleFIN }

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
    /// `/enablebanking/status`, asked only when an account is linked to
    /// Enable Banking.
    private(set) var enableBankingSupport: SimpleFINServerSupport?
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
        accountLines.contains(where: isDownloadable)
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
        simpleFINAvailable && !isSyncing && sessionIsCurrent
    }

    /// Background bank sync runs only through the server.
    var canEnableBackgroundSync: Bool {
        serverSupport == .configured || enableBankingSupport == .configured
    }

    /// The SimpleFIN setup-token section is for budgets that use SimpleFIN:
    /// hidden when the server serves Enable Banking and nothing here uses
    /// SimpleFIN.
    var showsSimpleFINTokenSection: Bool {
        guard serverSupport != .configured else { return false }
        return hasDeviceKey
            || enableBankingSupport != .configured
            || accountLines.contains { $0.provider == .simpleFIN }
    }

    var canClaimDeviceToken: Bool {
        !isClaiming
            && !isSyncing
            && sessionIsCurrent
            && !draftSetupToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// SimpleFIN downloads through the server, or the device key when the
    /// server has none.
    private var simpleFINAvailable: Bool {
        serverSupport == .configured || hasDeviceKey
    }

    /// Whether Sync All downloads this account now.
    private func isDownloadable(_ line: AccountLine) -> Bool {
        switch line.provider {
        case .simpleFIN: simpleFINAvailable
        case .enableBanking: enableBankingSupport == .configured
        case nil: false
        }
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
    /// Identifies the latest remote-accounts request so a superseded one only
    /// resets `.loading` when no newer request owns it.
    private var remoteAccountsRequest = 0
    /// A link or unlink write (and its refresh) is running; a second tap must
    /// not issue another write.
    private var isLinkWriteInFlight = false

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
            let rows = try await store.bankSync.bankSyncAccountRows(budgetID: budgetID)
            // The last-run record is display-only; an unreadable one must not
            // block Sync All.
            let persistedRun = try? await store.bankSync.bankSyncLastRun(budgetID: budgetID)
            guard sessionIsCurrent, generation == loadGeneration else { return }
            try Task.checkCancellation()
            accountLines = rows.map { $0.toLine(lastRunFailure: persistedRun?.failure) }
            lastRun = persistedRun
            if isDemoMode {
                serverSupport = nil
                enableBankingSupport = nil
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
                hasDeviceKey = try store.bankSync.hasBankSyncDeviceKey()
            } catch {
                hasDeviceKey = false
                throw error
            }
            applyCachedSession()
            if phase != .ready {
                phase = .loading
            }
            do {
                let support = try await store.bankSync.bankSyncSupport(budgetID: budgetID)
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
                } else if store.bankSync.cachedBankSyncSupport() != nil {
                    phase = .ready
                } else {
                    phase = error.userFacingMessage.map(Phase.failed) ?? .ready
                }
            }
            await loadEnableBankingSupport(generation: generation)
        } catch {
            guard sessionIsCurrent, generation == loadGeneration else { return }
            phase = error.userFacingMessage.map(Phase.failed) ?? .ready
        }
    }

    #if DEBUG
    /// Shows `BankSyncScreenPreview` instead of asking the server.
    func loadPreview() async {
        guard let rows = try? await store.bankSync.bankSyncAccountRows(budgetID: budgetID) else { return }
        let preview = BankSyncScreenPreview(accounts: rows)
        accountLines = preview.rows.map { $0.toLine(lastRunFailure: nil) }
        serverSupport = .configured
        enableBankingSupport = .configured
        lastRun = preview.lastRun
        resultLines = preview.resultLines
        phase = .ready
    }
    #endif

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
        remoteAccountsRequest += 1
        let request = remoteAccountsRequest
        let generation = loadGeneration
        // Superseded results are dropped. If this request still owns a
        // `.loading` status, return it to idle so a later call can retry.
        func isCurrent() -> Bool {
            guard sessionIsCurrent else { return false }
            if generation != loadGeneration {
                if request == remoteAccountsRequest, case .loading = remoteAccountsStatus {
                    remoteAccountsStatus = .idle
                }
                return false
            }
            return true
        }
        do {
            let accounts = try await store.bankSync.bankSyncRemoteAccounts(budgetID: budgetID)
            guard isCurrent() else { return }
            try Task.checkCancellation()
            remoteAccounts = accounts
            remoteAccountsStatus = .ready
        } catch where error.isCancellation {
            guard isCurrent() else { return }
            if case .loading = remoteAccountsStatus {
                remoteAccountsStatus = .idle
            }
        } catch {
            guard isCurrent() else { return }
            remoteAccountsStatus = error.userFacingMessage.map(RemoteAccountsStatus.failed) ?? .idle
        }
    }

    private var usesEnableBanking: Bool {
        accountLines.contains { $0.provider == .enableBanking }
    }

    private func applyCachedSession() {
        if let cached = store.bankSync.cachedBankSyncSupport() {
            serverSupport = cached
            phase = .ready
        }
        enableBankingSupport = usesEnableBanking ? store.enableBanking.cachedSupport() : nil
        _ = applyCachedRemoteAccounts()
    }

    /// A failed probe keeps a cached answer. A configured answer also clears
    /// a SimpleFIN probe failure: the server is reachable and Sync All can
    /// run for the Enable Banking accounts.
    private func loadEnableBankingSupport(generation: Int) async {
        guard usesEnableBanking else {
            enableBankingSupport = nil
            return
        }
        do {
            let support = try await store.enableBanking.support(budgetID: budgetID)
            guard sessionIsCurrent, generation == loadGeneration else { return }
            enableBankingSupport = support
            if support == .configured, isFailed {
                phase = .ready
            }
        } catch {
            guard sessionIsCurrent, generation == loadGeneration else { return }
            enableBankingSupport = store.enableBanking.cachedSupport()
        }
    }

    @discardableResult
    private func applyCachedRemoteAccounts() -> Bool {
        if let remotes = store.bankSync.cachedBankSyncRemoteAccounts() {
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
        let syncableAccountIDs = accountLines.filter(isDownloadable).map(\.id)
        var tally = BankSyncRunTally()
        var applyingAccountName: String?
        do {
            let run = try await store.bankSyncPlans.downloadBankSyncRun(
                accountIDs: syncableAccountIDs,
                budgetID: budgetID
            )
            let plans = run.plans
            guard sessionIsCurrent else { return }
            try Task.checkCancellation()
            guard !plans.isEmpty else {
                if let failure = run.simpleFINFailure { throw failure }
                phase = .failed("Nothing to sync.")
                return
            }
            guard plans.allSatisfy(\.problems.isEmpty) else {
                resultLines = plans.map {
                    $0.toLine(accountNames: accountNames, currency: currency, applied: false)
                }
                await recordRun(BankSyncRunTally.nothingSavedSummary)
                phase = .failed("Nothing was saved. Some bank transactions could not be read. See the details below.")
                return
            }
            phase = .applying
            // A failed SimpleFIN batch has one cause, shown in the last
            // result. Its accounts still commit their durable status but get
            // no result line; other providers' accounts keep theirs.
            for plan in plans {
                guard sessionIsCurrent else { return }
                try Task.checkCancellation()
                applyingAccountName = accountNames[plan.link.accountID] ?? "Account"
                let result: BankSyncReview.ApplyResult
                var refreshFailure: BankSyncCommittedRefreshError?
                do {
                    result = try await store.bankSync.applyBankSyncPlan(plan, budgetID: budgetID)
                } catch let error as BankSyncCommittedRefreshError {
                    result = error.result
                    refreshFailure = error
                }
                guard sessionIsCurrent else { return }
                tally.record(result, skipped: plan.durableStatus != .ok)
                if plan.wholeRequestFailure == nil {
                    resultLines.append(plan.toLine(accountNames: accountNames, currency: currency, applied: true))
                }
                if let refreshFailure { throw refreshFailure }
            }
            let outcome = tally.completedOutcome(plans: plans, simpleFINFailed: run.simpleFINFailure != nil)
            await recordRun(outcome.summary, failure: outcome.failure)
            if let failure = run.simpleFINFailure {
                // The Enable Banking accounts are saved; say why SimpleFIN's are not.
                phase = .failed(BankSyncRunTally.simpleFINNotSyncedNote
                    + (failure.userFacingMessage.map { " \($0)" } ?? ""))
            } else {
                phase = .ready
            }
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
            let rows = try await store.bankSync.bankSyncAccountRows(budgetID: budgetID)
            guard sessionIsCurrent else { return }
            accountLines = rows.map { $0.toLine(lastRunFailure: lastRun?.failure) }
        } catch {
            // The run outcome remains authoritative if the status read fails.
        }
        guard sessionIsCurrent else { return }
        phase = outcome
    }

    /// Publishes the run immediately and persists it for later visits. Call
    /// while the phase still rejects Sync All. The record is display-only, so
    /// a failed save keeps the run's own outcome.
    private func recordRun(_ summary: String?, failure: BankSyncWholeRequestFailure? = nil) async {
        guard let summary, sessionIsCurrent else { return }
        let run = BankSyncLastRun(finishedAt: Date(), trigger: .manual, summary: summary, failure: failure)
        lastRun = run
        try? await store.bankSync.recordBankSyncLastRun(run, budgetID: budgetID)
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
            try await store.bankSync.claimBankSyncDeviceToken(draftSetupToken)
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
            try store.bankSync.forgetBankSyncDeviceKey()
            hasDeviceKey = try store.bankSync.hasBankSyncDeviceKey()
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
        guard line.canUnlink,
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
        guard let accountID = selectedAccountID, !isLinkWriteInFlight else {
            return
        }
        isLinkWriteInFlight = true
        defer { isLinkWriteInFlight = false }
        do {
            try await store.bankSync.linkBankAccount(accountID, to: remote, budgetID: budgetID)
            selectedAccountID = nil
            await load()
        } catch {
            phase = error.userFacingMessage.map(Phase.failed) ?? .ready
        }
    }

    func unlinkSelected() async {
        guard let line = selectedLine, !isLinkWriteInFlight else {
            return
        }
        guard line.canUnlink else {
            phase = .failed(
                BankSyncWorkflows.BankSyncStoreError.notSimpleFINLinked.localizedDescription
            )
            return
        }
        let accountID = line.id
        isLinkWriteInFlight = true
        defer { isLinkWriteInFlight = false }
        do {
            try await store.bankSync.unlinkBankAccount(accountID, budgetID: budgetID)
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

private extension BankSyncWorkflows.BankSyncAccountStatusRow {
    func toLine(lastRunFailure: BankSyncWholeRequestFailure?) -> BankSyncViewModel.AccountLine {
        let provider = isLinked ? BankSyncProviderKind(syncSource: syncSource) : nil
        return BankSyncViewModel.AccountLine(
            id: id,
            name: name,
            isLinked: isLinked,
            provider: provider,
            remoteAccountID: remoteAccountID,
            lastSyncText: BankSyncCopy.lastSyncText(
                epochMilliseconds: lastSyncEpochMilliseconds,
                isLinked: isLinked
            ),
            statusText: BankSyncCopy.statusText(
                durableStatus: durableStatus,
                lastRunFailure: lastRunFailure,
                provider: provider
            ),
            statusColorKind: BankSyncCopy.statusColorKind(
                durableStatus: durableStatus,
                isLinked: isLinked
            ),
            linkedFooterText: BankSyncCopy.linkedFooter(provider: provider, durableStatus: durableStatus)
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
                : "Skipped · \(BankSyncCopy.statusText(durableStatus: durableStatus.rawValue, provider: BankSyncProviderKind(syncSource: link.syncSource)) ?? "Failed")",
            openingBalanceText: (applied ? openingBalance : nil).map {
                currency.formatted($0.amountMinorUnits)
            }
        )
    }
}
