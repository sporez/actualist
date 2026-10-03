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
            hasDeviceKey = false
            hasDeviceKey = try store.hasBankSyncDeviceKey()
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
        do {
            let accounts = try await store.bankSyncRemoteAccounts(budgetID: budgetID)
            guard sessionIsCurrent else { return }
            try Task.checkCancellation()
            remoteAccounts = accounts
            remoteAccountsStatus = .ready
        } catch where error.isCancellation {
            guard sessionIsCurrent else { return }
            if case .loading = remoteAccountsStatus {
                remoteAccountsStatus = .idle
            }
        } catch {
            guard sessionIsCurrent else { return }
            remoteAccountsStatus = .failed(error.localizedDescription)
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

/// Shared copy for the Bank Sync screen. Kept out of the views so the
/// decision-log wording (server-shared connection, never a token) lives in
/// one place.
enum BankSyncCopy {
    static func lastSyncText(epochMilliseconds: Int64?, isLinked: Bool) -> String {
        guard isLinked else {
            return "Not linked"
        }
        guard let epochMilliseconds else {
            return "Never synced"
        }
        let date = Date(timeIntervalSince1970: TimeInterval(epochMilliseconds) / 1_000)
        return "Synced " + relativeAgeText(since: date, now: Date())
    }

    static func relativeAgeText(since date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 {
            return "just now"
        }
        let minutes = Int(seconds / 60)
        if minutes < 1 {
            return "<1m ago"
        }
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }
        return "\(hours / 24)d ago"
    }

    static func statusText(durableStatus: String?) -> String? {
        guard let durableStatus, durableStatus != "ok" else {
            return nil
        }
        switch durableStatus {
        case "attention-required":
            return "Needs attention"
        case "reauth-required":
            return "Reconnect required"
        case "rate-limit-exceeded":
            return "Rate limited"
        case "timed-out":
            return "Timed out"
        case "account-missing":
            return "Account missing at bank"
        default:
            return "Failed"
        }
    }

    static func statusColorKind(durableStatus: String?, isLinked: Bool) -> BankSyncViewModel.AccountLine.StatusColorKind {
        guard isLinked else {
            return .none
        }
        switch durableStatus {
        case nil, "ok":
            return .healthy
        case "pending", "sync-requested":
            return .pending
        default:
            return .failed
        }
    }

    static func providerText(support: SimpleFINServerSupport?, hasDeviceKey: Bool, isDemoMode: Bool) -> String {
        if isDemoMode {
            return "Unavailable in demo mode"
        }
        switch support {
        case .configured:
            return "SimpleFIN via your server"
        case .notConfigured, .unsupported, nil:
            return hasDeviceKey ? "SimpleFIN via a device token" : "Not connected"
        }
    }

    static func connectionFooter(support: SimpleFINServerSupport?, hasDeviceKey: Bool, isDemoMode: Bool) -> String? {
        if isDemoMode {
            return "Demo budgets never contact a server, so bank sync is unavailable."
        }
        switch support {
        case .configured:
            return "This app and the Actual web UI share the same server connection."
        case .notConfigured:
            if hasDeviceKey {
                return deviceTokenFooter
            }
            return "Your server has no SimpleFIN setup token yet. Add one on the server, or connect with a SimpleFIN setup token below."
        case .unsupported, nil:
            if hasDeviceKey {
                return deviceTokenFooter
            }
            return "Your Actual server does not host the SimpleFIN routes. Connect with a SimpleFIN setup token below instead."
        }
    }

    static let deviceTokenFooter = "Connected with a SimpleFIN setup token on this device. The Actual web UI cannot refresh these links, because the access key is only stored here."

    static func dayText(_ dayID: String) -> String {
        guard dayID.count == 8 else {
            return dayID
        }
        return "\(dayID.prefix(4))-\(dayID.dropFirst(4).prefix(2))-\(dayID.suffix(2))"
    }

    static func matchChangeText(_ change: BankSyncReview.MatchChange) -> String {
        switch change.field {
        case .bankIDAttached:
            return "Attach bank transaction ID"
        case .bankIDReplaced:
            return "Replace existing bank transaction ID"
        case .payee:
            return "Payee: \(value(change.oldValue, empty: "None")) → \(value(change.newValue, empty: "None"))"
        case .category:
            return "Category: \(value(change.oldValue, empty: "Uncategorized")) → \(value(change.newValue, empty: "Uncategorized"))"
        case .bankPayee:
            return "Bank payee: \(quoted(change.oldValue)) → \(quoted(change.newValue))"
        case .notes:
            return "Notes: \(quoted(change.oldValue)) → \(quoted(change.newValue))"
        case .cleared:
            return "Cleared: \(boolText(change.oldValue)) → \(boolText(change.newValue))"
        case .splitChildrenCleared:
            let count = Int(change.newValue ?? "") ?? 0
            return count == 1
                ? "Mark 1 split transaction cleared"
                : "Mark \(count) split transactions cleared"
        }
    }

    private static func value(_ raw: String?, empty fallback: String) -> String {
        guard let raw, !raw.isEmpty else {
            return fallback
        }
        return raw
    }

    private static func quoted(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else {
            return "None"
        }
        return "“\(raw)”"
    }

    private static func boolText(_ raw: String?) -> String {
        raw == "true" ? "Yes" : "No"
    }

    static func problemSummary(_ problems: [BankSyncReview.Problem]) -> String? {
        guard !problems.isEmpty else {
            return nil
        }
        let counts = Dictionary(grouping: problems, by: \.message)
            .mapValues(\.count)
        return counts.keys.sorted().map { message in
            "\(counts[message] ?? 0)× \(message)"
        }.joined(separator: " · ")
    }

    static func backgroundSyncFooter(
        support: SimpleFINServerSupport?,
        phase: BankSyncViewModel.Phase,
        isDemoMode: Bool
    ) -> String {
        if isDemoMode {
            return "Unavailable in demo mode."
        }
        if phase == .idle || phase == .loading {
            return "Checking your server…"
        }
        guard support == .configured else {
            return "Requires SimpleFIN through your Actual server. Device-only tokens are not used for background sync."
        }
        return "After a background budget sync, linked bank accounts are downloaded and saved automatically. No notification is posted for this."
    }

    /// "Sync All · 2h ago" / "Background sync · just now".
    static func lastRunCaption(_ run: BankSyncLastRun, now: Date) -> String {
        let source = run.trigger == .background ? "Background sync" : "Sync All"
        return "\(source) · \(relativeAgeText(since: run.finishedAt, now: now))"
    }

}
