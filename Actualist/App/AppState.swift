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
    var localDataRevision: UInt64 = 0
    var themeRevision = 0
    var developerUnlockToastMessage: String?
    private(set) var isAppSwitcherCoverSuppressedForSystemUI = false

    private let settingsStore: AppSettingsStore
    private let keychain: KeychainStore
    @ObservationIgnored private let notificationAuthorizationRequester: @MainActor () async throws -> Bool
    @ObservationIgnored private let backgroundRefreshRunner = BackgroundTransactionRefreshRunner()
    @ObservationIgnored private let transactionNotifications = NewTransactionNotificationCoordinator()
    @ObservationIgnored private let providedLocalFirstStore: LocalFirstActualStore?
    @ObservationIgnored private var foregroundSessionActive = false
    @ObservationIgnored private var automaticSyncRequestedThisForeground = false
    @ObservationIgnored private var localFirstRefreshTask: Task<Bool, Never>?
    @ObservationIgnored private var localFirstRefreshTaskID: UUID?
    @ObservationIgnored private var localFirstRefreshBudgetID: String?
    private var developerUnlockTapCount = 0
    private var developerUnlockLastTapDate: Date?
    private let developerUnlockRequiredTapCount = 10
    private let developerUnlockVisibleCountdownThreshold = 5
    private let developerUnlockResetInterval: TimeInterval = 20

    /// The native local-first CRDT store: the app's only sync backend and source of truth.
    @ObservationIgnored lazy var localFirstStore: LocalFirstActualStore = {
        if let providedLocalFirstStore {
            return providedLocalFirstStore
        }
        return LocalFirstActualStore(
            keychain: keychain,
            syncDebugRecorder: { [weak self] event in
                self?.recordLocalFirstSyncDebugEvent(event)
            }
        )
    }()

    init(
        settingsStore: AppSettingsStore = .live,
        keychain: KeychainStore = .actualist,
        localFirstStore: LocalFirstActualStore? = nil,
        notificationAuthorizationRequester: @escaping @MainActor () async throws -> Bool = {
            try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    ) {
        self.settingsStore = settingsStore
        self.keychain = keychain
        self.notificationAuthorizationRequester = notificationAuthorizationRequester
        self.providedLocalFirstStore = localFirstStore
        let loaded = settingsStore.load()
        self.settings = loaded
        ActualistTheme.activate(loaded.theme)
        if loaded.selectedBudgetID != nil,
           loaded.selectedLocalFirstFileID != nil {
            self.setupPhase = .restoringBudget
            self.connectionStatus = keychain.readActualSyncToken().isEmpty ? .offline : .connecting
        } else if loaded.localFirstServerURLString.isEmpty
            || keychain.readActualSyncToken().isEmpty {
            self.setupPhase = .needsConnection
            self.connectionStatus = .offline
        } else {
            self.setupPhase = .selectingBudget
            self.connectionStatus = .online
        }
    }

    var canUseAPI: Bool {
        !settings.localFirstServerURLString.isEmpty && !keychain.readActualSyncToken().isEmpty
    }

    /// The single source of truth for backend availability. The local-first CRDT backend is
    /// the only sync path; proven mutations are normal product capabilities, while unsupported
    /// and experimental surfaces remain explicitly unavailable elsewhere.
    var capabilities: BackendCapabilities {
        .localFirst
    }

    func saveLocalFirstConnection(serverURLString: String, password: String) async -> Bool {
        let normalized = ActualServerURLNormalizer.normalize(serverURLString)
        guard !normalized.isEmpty else {
            lastErrorMessage = LocalFirstError.missingServerURL.localizedDescription
            return false
        }
        if let blockedMessage = ActualServerConnectionSecurity.blockedMessage(for: normalized) {
            lastErrorMessage = blockedMessage
            return false
        }

        let previousServerURLString = settings.localFirstServerURLString
        let serverChanged = !previousServerURLString.isEmpty && previousServerURLString != normalized
        let targetBudgetID = serverChanged ? nil : settings.selectedBudgetID

        do {
            let staged = try await localFirstStore.stageConnection(
                serverURLString: normalized,
                password: password,
                selectedBudgetID: targetBudgetID
            )
            if let targetBudgetID,
               let target = staged.budgets.first(where: { $0.syncID == targetBudgetID }) {
                try await localFirstStore.validateCachedBudgetCanOpen(target)
            }

            try localFirstStore.commitConnection(staged)
            settings.localFirstServerURLString = normalized
            budgets = Self.uniqueBudgets(staged.budgets)
            if serverChanged {
                settings.pendingNewTransactionIDsByAccount = [:]
                settings.backgroundTransactionRefreshEnabled = false
                settings.selectedBudgetID = nil
                settings.selectedBudgetName = nil
                settings.selectedLocalFirstFileID = nil
                settings.selectedLocalFirstGroupID = nil
                localFirstStore.reset()
                localFirstStore.remoteFilesByFileID = staged.remoteFilesByFileID
                localFirstStore.cachedBudgets = staged.budgets
                accountNavigationPath = []
                selectedBudget = nil
            }
            settingsStore.save(settings)

            if let targetBudgetID,
               let target = budgets.first(where: { $0.syncID == targetBudgetID }) {
                if !localFirstStore.isOpen(budgetID: targetBudgetID) {
                    _ = try await localFirstStore.openCachedBudget(target)
                }
                selectedBudget = target
                setupPhase = .ready
            } else {
                setupPhase = .selectingBudget
            }
            connectionStatus = .online
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            if previousServerURLString.isEmpty && !canUseAPI {
                connectionStatus = .offline
                setupPhase = .needsConnection
            }
            return false
        }
    }

    func disconnectAndEraseLocalData() {
        do {
            cancelLocalFirstRefresh()
            try localFirstStore.eraseLocalData()
            settings.localFirstServerURLString = ""
            settings.selectedBudgetID = nil
            settings.selectedBudgetName = nil
            settings.selectedLocalFirstFileID = nil
            settings.selectedLocalFirstGroupID = nil
            settings.pendingNewTransactionIDsByAccount = [:]
            settings.backgroundTransactionRefreshEnabled = false
            settingsStore.save(settings)
            selectedBudget = nil
            budgets = []
            accountNavigationPath = []
            setupPhase = .needsConnection
            connectionStatus = .offline
            lastErrorMessage = nil
            localDataRevision &+= 1
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

    /// Starts one foreground session. The selected SQLite budget is restored before the main
    /// tabs appear, then one coalesced CRDT sync revalidates that local source in the background.
    func beginForegroundSession() async {
        guard !foregroundSessionActive else {
            return
        }
        foregroundSessionActive = true
        automaticSyncRequestedThisForeground = false

        if setupPhase == .restoringBudget {
            await restoreSelectedBudgetForLaunch()
        }

        guard setupPhase == .ready,
              let budgetID = settings.selectedBudgetID else {
            return
        }

        _ = await refreshLocalFirstData(budgetID: budgetID, force: false)
    }

    func endForegroundSession() {
        foregroundSessionActive = false
        automaticSyncRequestedThisForeground = false
    }

    /// Pulls CRDT messages and reloads native caches without ever hiding an existing local
    /// snapshot. Automatic requests run once per foreground; forced requests power every
    /// pull-to-refresh and refresh button. Concurrent requests join the same in-flight task.
    @discardableResult
    func refreshLocalFirstData(budgetID: String, force: Bool = true) async -> Bool {
        guard localFirstStore.isOpen(budgetID: budgetID) else {
            return false
        }

        if let task = localFirstRefreshTask,
           localFirstRefreshBudgetID == budgetID {
            return await task.value
        }

        if !force {
            guard !automaticSyncRequestedThisForeground else {
                return true
            }
            automaticSyncRequestedThisForeground = true
        }

        let requestID = UUID()
        localFirstRefreshTaskID = requestID
        localFirstRefreshBudgetID = budgetID
        connectionStatus = .connecting

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return false
            }

            do {
                try await self.localFirstStore.refresh(
                    budgetID: budgetID,
                    serverURLString: self.settings.localFirstServerURLString
                )
                guard !Task.isCancelled,
                      self.settings.selectedBudgetID == budgetID,
                      self.localFirstStore.isOpen(budgetID: budgetID) else {
                    return false
                }
                self.connectionStatus = .online
                self.lastErrorMessage = nil
                self.localDataRevision &+= 1
                return true
            } catch is CancellationError {
                return false
            } catch {
                guard self.settings.selectedBudgetID == budgetID else {
                    return false
                }
                self.lastErrorMessage = error.localizedDescription
                self.connectionStatus = .offline
                return false
            }
        }
        localFirstRefreshTask = task
        let succeeded = await task.value
        if localFirstRefreshTaskID == requestID {
            localFirstRefreshTask = nil
            localFirstRefreshTaskID = nil
            localFirstRefreshBudgetID = nil
        }
        return succeeded
    }

    func retryPendingLocalFirstSync() async {
        await localFirstStore.retryPendingLocalMessageFlush()
    }

    private func recordLocalFirstSyncDebugEvent(_ event: LocalFirstSyncDebugEvent) {
        settings.localFirstSyncDebug.totalEventCount += 1
        settings.localFirstSyncDebug.recentEvents.insert(event, at: 0)
        settings.localFirstSyncDebug.recentEvents = Array(
            settings.localFirstSyncDebug.recentEvents.prefix(50)
        )
        settingsStore.save(settings)
    }

    /// Discard the locally imported budget and re-download a fresh copy from the server.
    /// A no-op when no budget is selected.
    func reimportLocalFirstBudget() async {
        guard let budget = selectedBudget else {
            return
        }

        cancelLocalFirstRefresh()
        connectionStatus = .connecting
        do {
            try await localFirstStore.reimportBudget(
                budget,
                serverURLString: settings.localFirstServerURLString
            )
            connectionStatus = .online
            lastErrorMessage = nil
            localDataRevision &+= 1
        } catch {
            lastErrorMessage = error.localizedDescription
            connectionStatus = localFirstStore.isOpen(budgetID: budget.syncID) ? .online : .offline
        }
    }

    private func selectLocalFirstBudget(_ budget: ActualBudget, encryptionPassword: String? = nil) async {
        if settings.selectedBudgetID != budget.syncID {
            cancelLocalFirstRefresh()
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
            localDataRevision &+= 1
        } catch {
            lastErrorMessage = error.localizedDescription
            connectionStatus = .offline
        }
    }

    func clearSelectionForBudgetChange() {
        cancelLocalFirstRefresh()
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

    func updateGreenIncomeTransactionAmountsEnabled(_ isEnabled: Bool) {
        settings.greenIncomeTransactionAmountsEnabled = isEnabled
        settingsStore.save(settings)
    }

    func updateIncludeCarryoverCategoriesInOverspentAlerts(_ isEnabled: Bool) {
        settings.includeCarryoverCategoriesInOverspentAlerts = isEnabled
        settingsStore.save(settings)
    }

    func updateRandomizedDisplayValuesEnabled(_ isEnabled: Bool) {
        settings.randomizedDisplayValuesEnabled = isEnabled
        settingsStore.save(settings)
    }

    func updateAppSwitcherPrivacyMode(_ mode: AppSwitcherPrivacyMode) {
        settings.appSwitcherPrivacyMode = mode
        if mode != .always {
            isAppSwitcherCoverSuppressedForSystemUI = false
        }
        settingsStore.save(settings)
    }

    func beginAppInitiatedSystemUIPresentation() {
        guard settings.appSwitcherPrivacyMode == .always else {
            return
        }
        isAppSwitcherCoverSuppressedForSystemUI = true
    }

    func clearAppInitiatedSystemUIPresentationSuppression() {
        isAppSwitcherCoverSuppressedForSystemUI = false
    }

    func isExperimentalFeatureEnabled(_ feature: ExperimentalFeature) -> Bool {
        settings.enabledExperimentalFeatures.contains(feature)
    }

    func updateExperimentalFeature(_ feature: ExperimentalFeature, isEnabled: Bool) {
        if isEnabled {
            settings.enabledExperimentalFeatures.insert(feature)
        } else {
            settings.enabledExperimentalFeatures.remove(feature)
        }
        settingsStore.save(settings)
    }

    var canApplyBudgetTemplates: Bool {
        isExperimentalFeatureEnabled(.budgetTemplates) && capabilities.canApplyBudgetTemplates
    }

    func updateDeveloperModeUnlocked(_ isUnlocked: Bool) {
        settings.developerModeUnlocked = isUnlocked
        if !isUnlocked {
            settings.randomizedDisplayValuesEnabled = false
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

    func updateReportCardOrder(_ reportCardOrder: [ReportCardKind]) {
        settings.reportCardOrder = ReportCardOrderPreference.normalized(reportCardOrder)
        settingsStore.save(settings)
    }

    func resetReportCardOrder() {
        settings.reportCardOrder = ReportCardOrderPreference.defaultOrder
        settingsStore.save(settings)
    }

    func updateBackgroundTransactionRefreshEnabled(_ isEnabled: Bool) async {
        if isEnabled {
            do {
                let granted = try await notificationAuthorizationRequester()
                guard granted else {
                    settings.backgroundTransactionRefreshEnabled = false
                    settingsStore.save(settings)
                    BackgroundTransactionRefreshCoordinator.shared.cancel()
                    return
                }
                try keychain.promoteAllItemsForBackgroundRefresh()
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

    func performBackgroundTransactionRefresh(
        timeLimit: Duration = .seconds(25)
    ) async -> Bool {
        let debugRunID = recordBackgroundRefreshWake()

        guard !Task.isCancelled else {
            recordBackgroundRefreshCompletion(
                runID: debugRunID,
                success: false,
                message: "Cancelled before sync"
            )
            return false
        }

        do {
            let outcome = try await backgroundRefreshRunner.run(
                settings: settings,
                selectedBudget: selectedBudget,
                budgets: budgets,
                canUseAPI: canUseAPI,
                store: localFirstStore,
                timeLimit: timeLimit
            )

            if case .synced(let result) = outcome {
                for pending in result.pendingTransactions {
                    recordPendingNewTransactionIDs(
                        pending.transactionIDs,
                        budgetID: result.budgetID,
                        accountID: pending.accountID
                    )
                }
                if result.newTransactionCount > 0 {
                    try await transactionNotifications.post(budgetID: result.budgetID)
                }
            }

            recordBackgroundRefreshCompletion(
                runID: debugRunID,
                success: true,
                message: outcome.message
            )
            return true
        } catch is CancellationError {
            recordBackgroundRefreshCompletion(
                runID: debugRunID,
                success: false,
                message: "Cancelled"
            )
            return false
        } catch BackgroundTransactionRefreshRunnerError.timeLimitExceeded {
            recordBackgroundRefreshCompletion(
                runID: debugRunID,
                success: false,
                message: "Timed out"
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
        await openSelectedCachedBudget(connectionStatus: .offline)
    }

    private func openSelectedCachedBudget(connectionStatus restoredStatus: ServerConnectionStatus) async -> Bool {
        guard let budget = selectedBudgetFromSettings() else {
            return false
        }

        do {
            let didOpen = try await localFirstStore.openCachedBudget(budget)
            guard didOpen else {
                return false
            }
            selectedBudget = budget
            budgets = Self.uniqueBudgets([budget] + budgets)
            setupPhase = .ready
            connectionStatus = restoredStatus
            localDataRevision &+= 1
            return true
        } catch {
            return false
        }
    }

    private func restoreSelectedBudgetForLaunch() async {
        if await openSelectedCachedBudget(connectionStatus: .connecting) {
            lastErrorMessage = nil
            return
        }

        do {
            try await loadBudgets()
        } catch {
            _ = await openSelectedCachedBudgetForOfflineUse()
        }
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
        transactionNotifications.pendingIDs(
            in: settings.pendingNewTransactionIDsByAccount,
            budgetID: budgetID,
            accountID: accountID
        )
    }

    /// Union of every account's pending-new IDs for the budget. Used by the cross-account
    /// Spending feed, where transactions aren't scoped to a single account.
    func pendingNewTransactionIDs(budgetID: String) -> Set<String> {
        transactionNotifications.pendingIDs(
            in: settings.pendingNewTransactionIDsByAccount,
            budgetID: budgetID
        )
    }

    func clearPendingNewTransactionIDs(budgetID: String, accountID: String) {
        guard transactionNotifications.clear(
            budgetID: budgetID,
            accountID: accountID,
            in: &settings.pendingNewTransactionIDsByAccount
        ) else {
            return
        }
        settingsStore.save(settings)
    }

    func clearPendingNewTransactionIDs(budgetID: String) {
        guard transactionNotifications.clear(
            budgetID: budgetID,
            in: &settings.pendingNewTransactionIDsByAccount
        ) else {
            return
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
        guard let repository = makeAccountRepository() else {
            throw DebugNotificationError.noAccounts
        }

        try await transactionNotifications.postDebug(
            budgetID: budgetID,
            repository: repository
        )
    }
    #endif

    func loadBudgets() async throws {
        guard !settings.localFirstServerURLString.isEmpty,
              !keychain.readActualSyncToken().isEmpty else {
            connectionStatus = .offline
            setupPhase = .needsConnection
            throw LocalFirstError.missingSyncToken
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
            lastErrorMessage = error.localizedDescription
            connectionStatus = .offline
            if settings.selectedBudgetID == nil {
                setupPhase = .needsConnection
            }
            throw error
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

    func makeReportsRepository() -> (any ReportsRepositoryProtocol)? {
        localFirstStore
    }

    private func recordPendingNewTransactionIDs(
        _ transactionIDs: [String],
        budgetID: String,
        accountID: String
    ) {
        transactionNotifications.record(
            transactionIDs,
            budgetID: budgetID,
            accountID: accountID,
            in: &settings.pendingNewTransactionIDsByAccount
        )
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

    private static func uniqueBudgets(_ budgets: [ActualBudget]) -> [ActualBudget] {
        var seenSyncIDs: Set<String> = []
        return budgets.filter { budget in
            seenSyncIDs.insert(budget.syncID).inserted
        }
    }

    private func cancelLocalFirstRefresh() {
        localFirstRefreshTask?.cancel()
        localFirstRefreshTask = nil
        localFirstRefreshTaskID = nil
        localFirstRefreshBudgetID = nil
    }
}

enum SetupPhase: Equatable {
    case needsConnection
    case selectingBudget
    case restoringBudget
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
