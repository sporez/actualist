import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class AppState {
    var settings: AppSettings
    var setupPhase: SetupPhase
    var selectedTab: AppTab = .budget
    var accountNavigationPath: [ActualAccount] = []
    var budgets: [ActualBudget] = []
    var selectedBudget: ActualBudget?
    var lastErrorMessage: String?
    var connectionStatus: ServerConnectionStatus = .connecting
    var themeRevision = 0
    var developerUnlockToastMessage: String?

    private let settingsStore: AppSettingsStore
    private let keychain: KeychainStore
    private var developerUnlockTapCount = 0
    private var developerUnlockLastTapDate: Date?
    private let developerUnlockRequiredTapCount = 10
    private let developerUnlockVisibleCountdownThreshold = 5
    private let developerUnlockResetInterval: TimeInterval = 20

    /// The native local-first CRDT store: the app's only sync backend and source of truth.
    @ObservationIgnored lazy var localFirstStore = LocalFirstActualStore(keychain: keychain)

    init(
        settingsStore: AppSettingsStore = .live,
        keychain: KeychainStore = .actualist
    ) {
        self.settingsStore = settingsStore
        self.keychain = keychain
        let loaded = settingsStore.load()
        self.settings = loaded
        ActualistTheme.activate(loaded.theme)
        if loaded.localFirstServerURLString.isEmpty
            || keychain.readActualSyncToken().isEmpty
            || loaded.selectedBudgetID == nil {
            self.setupPhase = .needsConnection
            self.connectionStatus = .offline
        } else {
            self.setupPhase = .ready
            self.connectionStatus = .connecting
        }
    }

    var canUseAPI: Bool {
        !settings.localFirstServerURLString.isEmpty && !keychain.readActualSyncToken().isEmpty
    }

    /// The single source of truth for backend read-only availability. The local-first CRDT
    /// backend is the only sync path and stays read-only until the CRDT write phase lands, so
    /// every write capability is gated off here.
    var capabilities: BackendCapabilities {
        BackendCapabilities(
            isLocalFirst: true,
            isReadOnly: true,
            allowsLocalFirstWrites: settings.localFirstWritesEnabled
        )
    }

    func saveLocalFirstConnection(serverURLString: String, password: String) async -> Bool {
        let normalized = ActualServerURLNormalizer.normalize(serverURLString)
        guard !normalized.isEmpty else {
            lastErrorMessage = LocalFirstError.missingServerURL.localizedDescription
            return false
        }
        if let blockedMessage = ActualServerConnectionSecurity.blockedMessage(for: normalized) {
            lastErrorMessage = blockedMessage
            connectionStatus = .offline
            return false
        }

        let previousServerURLString = settings.localFirstServerURLString
        let serverChanged = !previousServerURLString.isEmpty && previousServerURLString != normalized

        if serverChanged {
            do {
                try keychain.removeActualSyncToken()
                try keychain.removeAllLocalFirstEncryptionKeys()
            } catch {
                lastErrorMessage = error.localizedDescription
                connectionStatus = .offline
                return false
            }
        }

        settings.localFirstServerURLString = normalized
        if serverChanged {
            settings.pendingNewTransactionIDsByAccount = [:]
            settings.backgroundTransactionRefreshEnabled = false
            settings.selectedBudgetID = nil
            settings.selectedBudgetName = nil
            settings.selectedLocalFirstFileID = nil
            settings.selectedLocalFirstGroupID = nil
            localFirstStore.reset()
            accountNavigationPath = []
            selectedBudget = nil
        }
        settingsStore.save(settings)
        connectionStatus = .connecting

        do {
            try await localFirstStore.login(serverURLString: normalized, password: password)
            await loadBudgets()
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            connectionStatus = .offline
            if !canUseAPI {
                setupPhase = .needsConnection
            }
            return false
        }
    }

    func disconnectAndEraseLocalData() {
        do {
            try localFirstStore.eraseLocalData()
            settings.localFirstServerURLString = ""
            settings.selectedBudgetID = nil
            settings.selectedBudgetName = nil
            settings.selectedLocalFirstFileID = nil
            settings.selectedLocalFirstGroupID = nil
            settings.pendingNewTransactionIDsByAccount = [:]
            settings.backgroundTransactionRefreshEnabled = false
            settings.localFirstWritesEnabled = false
            settingsStore.save(settings)
            selectedBudget = nil
            budgets = []
            accountNavigationPath = []
            setupPhase = .needsConnection
            connectionStatus = .offline
            lastErrorMessage = nil
            BackgroundTransactionRefreshCoordinator.shared.cancel()
        } catch {
            lastErrorMessage = error.localizedDescription
            connectionStatus = .offline
        }
    }

    func selectBudgetForCurrentBackend(_ budget: ActualBudget, encryptionPassword: String? = nil) async {
        await selectLocalFirstBudget(budget, encryptionPassword: encryptionPassword)
    }

    var localFirstSyncStatus: LocalFirstSyncStatus? {
        guard let budgetID = settings.selectedBudgetID else {
            return nil
        }
        return localFirstStore.syncStatus(budgetID: budgetID)
    }

    /// Explicit local-first read refresh: pull CRDT messages and reload native caches.
    /// A no-op when no budget is open, so view load paths can call it unconditionally.
    func refreshLocalFirstData(budgetID: String) async {
        guard localFirstStore.hasOpenBudget else {
            return
        }

        connectionStatus = .connecting
        do {
            try await localFirstStore.refresh(
                budgetID: budgetID,
                serverURLString: settings.localFirstServerURLString
            )
            connectionStatus = .online
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            connectionStatus = .offline
        }
    }

    /// Discard the locally imported budget and re-download a fresh copy from the server.
    /// A no-op when no budget is selected.
    func reimportLocalFirstBudget() async {
        guard let budget = selectedBudget else {
            return
        }

        connectionStatus = .connecting
        do {
            try await localFirstStore.reimportBudget(
                budget,
                serverURLString: settings.localFirstServerURLString
            )
            connectionStatus = .online
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            connectionStatus = .offline
        }
    }

    private func selectLocalFirstBudget(_ budget: ActualBudget, encryptionPassword: String? = nil) async {
        if settings.selectedBudgetID != budget.syncID {
            localFirstStore.reset()
            accountNavigationPath = []
        }

        connectionStatus = .connecting
        do {
            try await localFirstStore.openBudget(
                budget,
                serverURLString: settings.localFirstServerURLString,
                encryptionPassword: encryptionPassword
            )
            selectedBudget = budget
            settings.selectedBudgetID = budget.syncID
            settings.selectedBudgetName = budget.name
            settings.selectedLocalFirstFileID = budget.localFirstFileID
            settings.selectedLocalFirstGroupID = budget.groupId
            settings.backgroundTransactionRefreshEnabled = false
            settingsStore.save(settings)
            setupPhase = .ready
            connectionStatus = .online
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            connectionStatus = .offline
        }
    }

    func clearSelectionForBudgetChange() {
        localFirstStore.reset()
        accountNavigationPath = []
        selectedBudget = nil
        settings.selectedBudgetID = nil
        settings.selectedBudgetName = nil
        settingsStore.save(settings)
        setupPhase = canUseAPI ? .selectingBudget : .needsConnection
    }

    func updateDisplayDensity(_ density: ActualistDisplayDensity) {
        settings.displayDensity = density
        settingsStore.save(settings)
    }

    func updateRandomizedDisplayValuesEnabled(_ isEnabled: Bool) {
        settings.randomizedDisplayValuesEnabled = isEnabled
        settingsStore.save(settings)
    }

    func updateLocalFirstWritesEnabled(_ isEnabled: Bool) {
        settings.localFirstWritesEnabled = isEnabled
        settingsStore.save(settings)
    }

    func updateDeveloperModeUnlocked(_ isUnlocked: Bool) {
        settings.developerModeUnlocked = isUnlocked
        if !isUnlocked {
            settings.randomizedDisplayValuesEnabled = false
            settings.localFirstWritesEnabled = false
        }
        resetDeveloperUnlockProgress()
        settingsStore.save(settings)
    }

    func recordDeveloperUnlockTap() -> String? {
        guard !settings.developerModeUnlocked else {
            return nil
        }

        let now = Date()
        if let developerUnlockLastTapDate,
           now.timeIntervalSince(developerUnlockLastTapDate) > developerUnlockResetInterval {
            developerUnlockTapCount = 0
        }

        developerUnlockLastTapDate = now
        developerUnlockTapCount += 1

        let remainingTaps = max(0, developerUnlockRequiredTapCount - developerUnlockTapCount)
        if remainingTaps == 0 {
            updateDeveloperModeUnlocked(true)
            return "You're a developer!"
        }

        guard remainingTaps <= developerUnlockVisibleCountdownThreshold else {
            return nil
        }

        let noun = remainingTaps == 1 ? "tap" : "taps"
        return "\(remainingTaps) \(noun) from Developer Mode"
    }

    func resetDeveloperUnlockProgress() {
        developerUnlockTapCount = 0
        developerUnlockLastTapDate = nil
    }

    func updateTheme(_ theme: ActualistThemeOption) {
        settings.theme = theme
        ActualistTheme.activate(theme)
        themeRevision += 1
        settingsStore.save(settings)
    }

    func orderedAccountDisplays(_ displays: [AccountDisplay], budgetID: String) -> [AccountDisplay] {
        AccountOrderPreference.ordered(
            displays,
            preferredIDs: settings.accountOrderByBudgetID[budgetID] ?? []
        )
    }

    func orderedAccounts(_ accounts: [ActualAccount], budgetID: String) -> [ActualAccount] {
        AccountOrderPreference.ordered(
            accounts,
            preferredIDs: settings.accountOrderByBudgetID[budgetID] ?? []
        )
    }

    func updateAccountOrder(_ accountIDs: [String], budgetID: String) {
        settings.accountOrderByBudgetID[budgetID] = accountIDs
        settingsStore.save(settings)
    }

    func resetAccountOrder(budgetID: String) {
        settings.accountOrderByBudgetID[budgetID] = nil
        settingsStore.save(settings)
    }

    func updateBackgroundTransactionRefreshEnabled(_ isEnabled: Bool) async {
        if isEnabled {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                guard granted else {
                    settings.backgroundTransactionRefreshEnabled = false
                    settingsStore.save(settings)
                    BackgroundTransactionRefreshCoordinator.shared.cancel()
                    return
                }
            } catch {
                settings.backgroundTransactionRefreshEnabled = false
                settingsStore.save(settings)
                lastErrorMessage = error.localizedDescription
                BackgroundTransactionRefreshCoordinator.shared.cancel()
                return
            }
        }

        settings.backgroundTransactionRefreshEnabled = isEnabled
        settingsStore.save(settings)
        if isEnabled {
            BackgroundTransactionRefreshCoordinator.shared.scheduleIfNeeded(for: self)
        } else {
            BackgroundTransactionRefreshCoordinator.shared.cancel()
        }
    }

    func performBackgroundTransactionRefresh() async -> Bool {
        let debugRunID = recordBackgroundRefreshWake()

        if Task.isCancelled {
            recordBackgroundRefreshCompletion(
                runID: debugRunID,
                success: false,
                message: "Cancelled before sync"
            )
            return false
        }

        if let skipReason = backgroundRefreshSkipReason() {
            recordBackgroundRefreshCompletion(
                runID: debugRunID,
                success: true,
                message: skipReason
            )
            return true
        }

        guard let budgetID = settings.selectedBudgetID else {
            recordBackgroundRefreshCompletion(
                runID: debugRunID,
                success: true,
                message: "Skipped: no selected budget"
            )
            return true
        }

        guard let budget = selectedBudgetForBackgroundRefresh(budgetID: budgetID) else {
            recordBackgroundRefreshCompletion(
                runID: debugRunID,
                success: true,
                message: "Skipped: selected budget metadata unavailable"
            )
            return true
        }

        do {
            if Task.isCancelled {
                throw CancellationError()
            }
            let results = try await localFirstStore.syncAndFindNewTransactions(
                budget: budget,
                serverURLString: settings.localFirstServerURLString
            )
            var newTransactionCount = 0

            if Task.isCancelled {
                throw CancellationError()
            }
            for result in results where !result.newTransactionIDs.isEmpty {
                if Task.isCancelled {
                    throw CancellationError()
                }
                recordPendingNewTransactionIDs(
                    result.newTransactionIDs,
                    budgetID: budgetID,
                    accountID: result.account.id
                )
                newTransactionCount += result.newTransactionIDs.count
            }

            if newTransactionCount > 0 {
                try await postNewTransactionsNotification(
                    budgetID: budgetID,
                    count: newTransactionCount
                )
            }

            recordBackgroundRefreshCompletion(
                runID: debugRunID,
                success: true,
                message: backgroundSyncCompletionMessage(
                    accountCount: results.count,
                    newTransactionCount: newTransactionCount
                )
            )
            return true
        } catch is CancellationError {
            recordBackgroundRefreshCompletion(
                runID: debugRunID,
                success: false,
                message: "Cancelled"
            )
            return false
        } catch {
            lastErrorMessage = error.localizedDescription
            recordBackgroundRefreshCompletion(
                runID: debugRunID,
                success: false,
                message: error.localizedDescription
            )
            return false
        }
    }

    private func selectedBudgetForBackgroundRefresh(budgetID: String) -> ActualBudget? {
        if let selectedBudget, selectedBudget.syncID == budgetID {
            return selectedBudget
        }
        if let budget = budgets.first(where: { $0.syncID == budgetID }) {
            return budget
        }
        guard let fileID = settings.selectedLocalFirstFileID else {
            return nil
        }
        return ActualBudget(
            budgetID: fileID,
            cloudFileId: fileID,
            groupId: settings.selectedLocalFirstGroupID,
            name: settings.selectedBudgetName ?? "Selected Budget",
            state: nil
        )
    }

    private func selectedBudgetFromSettings() -> ActualBudget? {
        guard settings.selectedBudgetID != nil,
              let fileID = settings.selectedLocalFirstFileID else {
            return nil
        }
        return ActualBudget(
            budgetID: fileID,
            cloudFileId: fileID,
            groupId: settings.selectedLocalFirstGroupID,
            name: settings.selectedBudgetName ?? "Selected Budget",
            state: nil
        )
    }

    private func openSelectedCachedBudgetForOfflineUse() async -> Bool {
        guard let budget = selectedBudgetFromSettings() else {
            return false
        }

        do {
            let didOpen = try await localFirstStore.openCachedBudget(budget)
            guard didOpen else {
                return false
            }
            selectedBudget = budget
            setupPhase = .ready
            connectionStatus = .offline
            return true
        } catch {
            return false
        }
    }

    private func backgroundSyncCompletionMessage(accountCount: Int, newTransactionCount: Int) -> String {
        if newTransactionCount == 0 {
            return "Synced budget; no new transactions"
        }
        let transactionNoun = newTransactionCount == 1 ? "transaction" : "transactions"
        let accountNoun = accountCount == 1 ? "account" : "accounts"
        return "Synced budget; found \(newTransactionCount) new \(transactionNoun) across \(accountCount) \(accountNoun)"
    }

    private func backgroundRefreshSkipReason() -> String? {
        var reasons: [String] = []
        if !settings.backgroundTransactionRefreshEnabled {
            reasons.append("alerts disabled")
        }
        if setupPhase != .ready {
            reasons.append("app not ready")
        }
        if settings.selectedBudgetID == nil {
            reasons.append("no selected budget")
        }
        if !canUseAPI {
            reasons.append("credentials missing")
        }

        guard !reasons.isEmpty else {
            return nil
        }
        return "Skipped: \(reasons.joined(separator: ", "))"
    }

    func recordBackgroundRefreshScheduleAttempt(
        succeeded: Bool,
        earliestBeginDate: Date?,
        message: String
    ) {
        let attempt = BackgroundRefreshScheduleAttempt(
            id: UUID(),
            date: Date(),
            earliestBeginDate: earliestBeginDate,
            succeeded: succeeded,
            message: message
        )
        settings.backgroundRefreshDebug.totalScheduleAttemptCount += 1
        settings.backgroundRefreshDebug.recentScheduleAttempts.insert(attempt, at: 0)
        if settings.backgroundRefreshDebug.recentScheduleAttempts.count > 20 {
            settings.backgroundRefreshDebug.recentScheduleAttempts.removeSubrange(20...)
        }
        settingsStore.save(settings)
    }

    func pendingNewTransactionIDs(budgetID: String, accountID: String) -> Set<String> {
        Set(settings.pendingNewTransactionIDsByAccount[pendingNewTransactionKey(budgetID: budgetID, accountID: accountID)] ?? [])
    }

    /// Union of every account's pending-new IDs for the budget. Used by the cross-account
    /// Spending feed, where transactions aren't scoped to a single account. Transaction IDs
    /// are globally unique, so the union is safe to flatten.
    func pendingNewTransactionIDs(budgetID: String) -> Set<String> {
        let prefix = "\(budgetID)|"
        return settings.pendingNewTransactionIDsByAccount.reduce(into: Set<String>()) { result, entry in
            guard entry.key.hasPrefix(prefix) else {
                return
            }
            result.formUnion(entry.value)
        }
    }

    func clearPendingNewTransactionIDs(budgetID: String, accountID: String) {
        let key = pendingNewTransactionKey(budgetID: budgetID, accountID: accountID)
        guard settings.pendingNewTransactionIDsByAccount[key] != nil else {
            return
        }
        settings.pendingNewTransactionIDsByAccount[key] = nil
        settingsStore.save(settings)
    }

    func clearPendingNewTransactionIDs(budgetID: String) {
        let prefix = "\(budgetID)|"
        let keys = settings.pendingNewTransactionIDsByAccount.keys.filter { $0.hasPrefix(prefix) }
        guard !keys.isEmpty else {
            return
        }
        for key in keys {
            settings.pendingNewTransactionIDsByAccount[key] = nil
        }
        settingsStore.save(settings)
    }

    func routeToSpendingFromNotification(budgetID: String) async {
        guard capabilities.supportsTransactionNotifications else {
            accountNavigationPath = []
            return
        }
        accountNavigationPath = []
        selectedTab = .spending
    }

    #if DEBUG
    func postDebugNewTransactionNotification() async throws {
        guard capabilities.supportsTransactionNotifications else {
            throw LocalFirstError.unsupportedWrite
        }
        guard let budgetID = settings.selectedBudgetID else {
            throw DebugNotificationError.missingBudget
        }

        let notificationCenter = UNUserNotificationCenter.current()
        let notificationSettings = await notificationCenter.notificationSettings()
        if notificationSettings.authorizationStatus != .authorized {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            guard granted else {
                throw DebugNotificationError.notificationsDenied
            }
        }

        guard let repository = makeAccountRepository() else {
            throw DebugNotificationError.noAccounts
        }
        if repository.accountDisplays(budgetID: budgetID).isEmpty {
            try await repository.refreshAccountsWithBalances(budgetID: budgetID)
        }

        let accounts = repository.accountDisplays(budgetID: budgetID).map(\.account)
        guard accounts.contains(where: { !$0.closed }) || !accounts.isEmpty else {
            throw DebugNotificationError.noAccounts
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        try await postNewTransactionsNotification(
            budgetID: budgetID,
            count: 1,
            trigger: trigger
        )
    }
    #endif

    func loadBudgets() async {
        guard !settings.localFirstServerURLString.isEmpty,
              !keychain.readActualSyncToken().isEmpty else {
            connectionStatus = .offline
            setupPhase = .needsConnection
            return
        }

        do {
            budgets = Self.uniqueBudgets(
                try await localFirstStore.loadBudgets(serverURLString: settings.localFirstServerURLString)
            )

            if budgets.count == 1, let budget = budgets.first, settings.selectedBudgetID == nil {
                await selectLocalFirstBudget(budget)
                return
            }

            if let selectedBudgetID = settings.selectedBudgetID,
               let budget = budgets.first(where: { $0.syncID == selectedBudgetID }) {
                selectedBudget = budget
                // Open only on first load; once open, refresh flows through
                // refreshLocalFirstData so appears don't reopen the DB or double-sync.
                if !localFirstStore.isOpen(budgetID: selectedBudgetID) {
                    try await localFirstStore.openBudget(
                        budget,
                        serverURLString: settings.localFirstServerURLString
                    )
                }
                setupPhase = .ready
                connectionStatus = .online
                return
            }

            connectionStatus = .online
            setupPhase = .selectingBudget
        } catch {
            if await openSelectedCachedBudgetForOfflineUse() {
                lastErrorMessage = nil
                return
            }

            lastErrorMessage = error.localizedDescription
            connectionStatus = .offline
            setupPhase = .needsConnection
        }
    }

    /// The local-first store as a budget repository. Always available; returns `nil` only to
    /// preserve the optional-based call sites that skip loading when unconfigured.
    func makeBudgetRepository() -> (any BudgetRepositoryProtocol)? {
        localFirstStore
    }

    func makeTransactionRepository() -> (any TransactionRepositoryProtocol)? {
        localFirstStore
    }

    func makeAccountRepository() -> (any AccountRepositoryProtocol)? {
        localFirstStore
    }

    private func pendingNewTransactionKey(budgetID: String, accountID: String) -> String {
        "\(budgetID)|\(accountID)"
    }

    private func recordPendingNewTransactionIDs(_ transactionIDs: [String], budgetID: String, accountID: String) {
        let key = pendingNewTransactionKey(budgetID: budgetID, accountID: accountID)
        var existing = Set(settings.pendingNewTransactionIDsByAccount[key] ?? [])
        existing.formUnion(transactionIDs)
        settings.pendingNewTransactionIDsByAccount[key] = existing.sorted()
        settingsStore.save(settings)
    }

    private func recordBackgroundRefreshWake() -> UUID {
        let runID = UUID()
        let run = BackgroundRefreshDebugRun(
            id: runID,
            wakeDate: Date(),
            completionDate: nil,
            succeeded: nil,
            message: "Started"
        )
        settings.backgroundRefreshDebug.totalWakeCount += 1
        settings.backgroundRefreshDebug.recentRuns.insert(run, at: 0)
        if settings.backgroundRefreshDebug.recentRuns.count > 20 {
            settings.backgroundRefreshDebug.recentRuns.removeSubrange(20...)
        }
        settingsStore.save(settings)
        return runID
    }

    private func recordBackgroundRefreshCompletion(runID: UUID, success: Bool, message: String) {
        guard let index = settings.backgroundRefreshDebug.recentRuns.firstIndex(where: { $0.id == runID }) else {
            return
        }

        settings.backgroundRefreshDebug.recentRuns[index].completionDate = Date()
        settings.backgroundRefreshDebug.recentRuns[index].succeeded = success
        settings.backgroundRefreshDebug.recentRuns[index].message = message
        settingsStore.save(settings)
    }

    private func postNewTransactionsNotification(
        budgetID: String,
        count _: Int,
        trigger: UNNotificationTrigger? = nil
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = NewTransactionsNotificationCopy.title
        content.body = NewTransactionsNotificationCopy.body
        content.sound = .default
        content.userInfo = [
            "budgetID": budgetID
        ]

        let request = UNNotificationRequest(
            identifier: "actualist.new-transactions.\(budgetID).\(Date().timeIntervalSince1970)",
            content: content,
            trigger: trigger
        )
        try await UNUserNotificationCenter.current().add(request)
    }

    private static func uniqueBudgets(_ budgets: [ActualBudget]) -> [ActualBudget] {
        var seenSyncIDs: Set<String> = []
        return budgets.filter { budget in
            seenSyncIDs.insert(budget.syncID).inserted
        }
    }
}

#if DEBUG
private enum DebugNotificationError: LocalizedError {
    case missingBudget
    case noAccounts
    case notificationsDenied

    var errorDescription: String? {
        switch self {
        case .missingBudget:
            "Select a budget before posting a test notification."
        case .noAccounts:
            "No accounts are loaded for the selected budget."
        case .notificationsDenied:
            "Notification permission is not granted."
        }
    }
}
#endif

enum SetupPhase: Equatable {
    case needsConnection
    case selectingBudget
    case ready
}

enum ServerConnectionStatus: Equatable {
    case online
    case connecting
    case offline
}

enum NewTransactionsNotificationCopy {
    static let title = "Actualist"
    static let body = "New transactions found"
}
