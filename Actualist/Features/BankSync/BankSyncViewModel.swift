import Foundation
import Observation

/// Screen state machine for the Settings → Budget & Data → Bank Sync page
/// (plan Phase 4, Settings-only MVP cut). Owns download/apply coordination
/// and derived display state; the views only render `BankSyncDisplay` and
/// call intents.
@MainActor
@Observable
final class BankSyncViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case downloading
        case reviewing
        case applying
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

    /// Per-account review section, pre-formatted for the review sheet.
    struct ReviewLine: Identifiable, Equatable {
        let id: String
        let accountName: String
        let addedCount: Int
        let updatedCount: Int
        let unchangedCount: Int
        let problemCount: Int
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
    private(set) var reviewLines: [ReviewLine] = []
    /// Downloaded plans behind `reviewLines`; held privately so the sheet
    /// only ever sees display values, and confirm applies exactly what was
    /// reviewed.
    private var reviewPlans: [BankSyncReview.AccountPlan] = []
    private(set) var selectedAccountID: String?
    /// Summary shown after a confirmed apply.
    private(set) var resultSummary: String?

    var isReviewPresented: Bool {
        phase == .reviewing
    }

    var canSyncAll: Bool {
        providerAvailable
            && accountLines.contains { $0.isSyncable }
            && phase == .ready
    }

    var canLinkAccounts: Bool {
        providerAvailable
    }

    var canClaimDeviceToken: Bool {
        !isClaiming
            && !draftSetupToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var providerAvailable: Bool {
        serverSupport == .configured || hasDeviceKey
    }

    var syncButtonTitle: String {
        phase == .downloading ? "Downloading…" : "Sync All"
    }

    private let store: LocalFirstActualStore
    private let budgetID: String
    private let currency: BudgetCurrency
    private let isDemoMode: Bool
    private let now: @Sendable () -> Date

    init(
        store: LocalFirstActualStore,
        budgetID: String,
        currency: BudgetCurrency,
        isDemoMode: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.budgetID = budgetID
        self.currency = currency
        self.isDemoMode = isDemoMode
        self.now = now
    }

    func load() async {
        // Deliberately keeps resultSummary so the last apply result survives
        // the post-apply reload.
        phase = .loading
        do {
            let rows = try await store.bankSyncAccountRows(budgetID: budgetID)
            accountLines = rows.map(\.toLine)
            if isDemoMode {
                serverSupport = nil
                hasDeviceKey = false
                phase = .ready
                return
            }
            // Read the device key before probing the server: a claimed token
            // must surface even when the server is unreachable or its
            // answer is unreadable (the provider resolution falls back to
            // the device key in exactly that case).
            hasDeviceKey = store.hasBankSyncDeviceKey()
            do {
                serverSupport = try await store.bankSyncSupport(budgetID: budgetID)
                if canLinkAccounts {
                    remoteAccounts = (try? await store.bankSyncRemoteAccounts(budgetID: budgetID)) ?? []
                }
                phase = .ready
            } catch {
                if hasDeviceKey {
                    serverSupport = nil
                    phase = .ready
                } else {
                    phase = .failed(BankSyncCopy.failureMessage(error))
                }
            }
        } catch {
            phase = .failed(BankSyncCopy.failureMessage(error))
        }
    }

    /// Download every syncable linked account, then present one review sheet.
    /// Writes nothing until `confirmReview`.
    func syncAll() async {
        guard phase == .ready else {
            return
        }
        phase = .downloading
        resultSummary = nil
        var collected: [BankSyncReview.AccountPlan] = []
        var failure: String?
        for line in accountLines where line.isSyncable {
            do {
                collected.append(try await store.downloadBankSyncPlan(
                    accountID: line.id,
                    budgetID: budgetID
                ))
            } catch {
                failure = BankSyncCopy.failureMessage(error)
                break
            }
        }
        guard failure == nil, !collected.isEmpty else {
            phase = .failed(failure ?? "Nothing to sync.")
            return
        }
        reviewPlans = collected
        let names = accountNames
        reviewLines = collected.map { $0.toLine(accountNames: names, currency: currency) }
        phase = .reviewing
    }

    func cancelReview() {
        guard phase == .reviewing else {
            return
        }
        reviewPlans = []
        reviewLines = []
        phase = .ready
    }

    /// Applies every reviewed plan in order. The plans were validated
    /// generation-wise at download time; the store refuses a stale one.
    func confirmReview() async {
        guard phase == .reviewing else {
            return
        }
        phase = .applying
        var inserted = 0
        var updated = 0
        var openings = 0
        do {
            for plan in reviewPlans {
                let result = try await store.applyBankSyncPlan(plan, budgetID: budgetID)
                inserted += result.insertedCount
                updated += result.updatedCount
                if result.openingBalanceInserted {
                    openings += 1
                }
            }
            reviewPlans = []
            reviewLines = []
            resultSummary = BankSyncCopy.applySummary(
                inserted: inserted,
                updated: updated,
                openings: openings
            )
            await load()
        } catch {
            phase = .failed(BankSyncCopy.failureMessage(error))
        }
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
            phase = .failed(BankSyncCopy.failureMessage(error))
        }
    }

    /// Disconnect forgets the device key only. Links and transactions stay.
    func forgetDeviceKey() async {
        do {
            try store.forgetBankSyncDeviceKey()
            hasDeviceKey = store.hasBankSyncDeviceKey()
            await load()
        } catch {
            phase = .failed(BankSyncCopy.failureMessage(error))
        }
    }

    // MARK: - Link / unlink sheet

    func selectAccount(_ id: String) {
        selectedAccountID = id
    }

    func dismissAccountSheet() {
        selectedAccountID = nil
    }

    var selectedLine: AccountLine? {
        accountLines.first { $0.id == selectedAccountID }
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
            phase = .failed(BankSyncCopy.failureMessage(error))
        }
    }

    func unlinkSelected() async {
        guard let accountID = selectedAccountID else {
            return
        }
        do {
            try await store.unlinkBankAccount(accountID, budgetID: budgetID)
            selectedAccountID = nil
            await load()
        } catch {
            phase = .failed(BankSyncCopy.failureMessage(error))
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
            isSyncable: isLinked && syncSource == "simpleFin",
            remoteAccountID: remoteAccountID,
            lastSyncText: BankSyncCopy.lastSyncText(epochMilliseconds: lastSyncEpochMilliseconds),
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
        currency: BudgetCurrency
    ) -> BankSyncViewModel.ReviewLine {
        BankSyncViewModel.ReviewLine(
            id: accountID,
            accountName: accountNames[accountID] ?? "Account",
            addedCount: inserts.count + (openingBalance != nil ? 1 : 0),
            updatedCount: updates.count,
            unchangedCount: unchangedCount,
            problemCount: problems.count,
            openingBalanceText: openingBalance.map {
                currency.formatted($0.amountMinorUnits)
            }
        )
    }
}

/// Shared copy for the Bank Sync screen. Kept out of the views so the
/// decision-log wording (server-shared connection, never a token) lives in
/// one place.
enum BankSyncCopy {
    static func lastSyncText(epochMilliseconds: Int64?) -> String {
        guard let epochMilliseconds else {
            return "Never synced"
        }
        let date = Date(timeIntervalSince1970: TimeInterval(epochMilliseconds) / 1_000)
        let seconds = Date().timeIntervalSince(date)
        if seconds < 45 {
            return "Synced just now"
        }
        let minutes = Int(seconds / 60)
        if minutes < 1 {
            return "Synced <1m ago"
        }
        if minutes < 60 {
            return "Synced \(minutes)m ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "Synced \(hours)h ago"
        }
        return "Synced \(hours / 24)d ago"
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

    static func applySummary(inserted: Int, updated: Int, openings: Int) -> String {
        var parts: [String] = []
        if inserted > 0 {
            parts.append(inserted == 1 ? "Added 1 transaction" : "Added \(inserted) transactions")
        }
        if updated > 0 {
            parts.append(updated == 1 ? "Updated 1 match" : "Updated \(updated) matches")
        }
        if openings > 0 {
            parts.append(openings == 1 ? "Added 1 opening balance" : "Added \(openings) opening balances")
        }
        return parts.isEmpty ? "Everything already matches." : parts.joined(separator: " · ")
    }

    static func failureMessage(_ error: Error) -> String {
        error.localizedDescription
    }
}
