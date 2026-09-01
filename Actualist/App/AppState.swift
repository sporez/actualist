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
    var requiresReauthentication = false
    var localDataRevision: UInt64 = 0
    var themeRevision = 0
    var developerUnlockToastMessage: String?
    private(set) var isAppSwitcherCoverSuppressedForSystemUI = false
    private(set) var isBudgetSwitchInProgress = false
    let routeCoordinator = AppRouteCoordinator()

    private let settingsStore: AppSettingsStore
    private let keychain: KeychainStore
    @ObservationIgnored private let appSyncCoordinator = AppSyncCoordinator()
    @ObservationIgnored private let backgroundTransactionWorkflow: BackgroundTransactionWorkflow
    @ObservationIgnored private let providedLocalFirstStore: LocalFirstActualStore?
    private var developerUnlockTracker = DeveloperUnlockTracker()

    @ObservationIgnored lazy var localFirstStore: LocalFirstActualStore = {
        let store = providedLocalFirstStore ?? LocalFirstActualStore(
            keychain: keychain,
            syncDebugRecorder: { [weak self] event in
                self?.recordLocalFirstSyncDebugEvent(event)
            }
        )
        store.fallbackServerURLString = settings.fallbackServerURLString.isEmpty
            ? nil
            : settings.fallbackServerURLString
        return store
    }()

    init(
        settingsStore: AppSettingsStore = .live,
        keychain: KeychainStore = .actualist,
        localFirstStore: LocalFirstActualStore? = nil,
        notificationAuthorizationRequester: @escaping @MainActor () async throws -> Bool = {
            try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
        },
        applicationBadgeUpdater: @escaping @MainActor (Int) -> Void = { badgeCount in
            Task {
                try? await UNUserNotificationCenter.current().setBadgeCount(badgeCount)
            }
        }
    ) {
        self.settingsStore = settingsStore
        self.keychain = keychain
        self.backgroundTransactionWorkflow = BackgroundTransactionWorkflow(
            settingsStore: settingsStore,
            notificationAuthorizationRequester: notificationAuthorizationRequester,
            applicationBadgeUpdater: applicationBadgeUpdater
        )
        self.providedLocalFirstStore = localFirstStore
        var loaded = settingsStore.load()
        if !loaded.isExperimentalFeatureEnabled(.bankSync), loaded.simplefinBackgroundSyncEnabled {
            loaded.simplefinBackgroundSyncEnabled = false
            settingsStore.save(loaded)
        }
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

    var hasSyncCredentials: Bool {
        !settings.localFirstServerURLString.isEmpty && !keychain.readActualSyncToken().isEmpty
    }

    /// `true` when the selected budget is the bundled demo budget. Derived from
    /// the persisted selection so launch restore and erase work for demo with
    /// no new settings keys. Presentation and store guards key off this.
    var isDemoMode: Bool {
        settings.selectedLocalFirstFileID == DemoBudget.fileID
    }

    /// Install and open the bundled demo budget, then route straight to the
    /// main app shell. Only valid from `.needsConnection` (onboarding). Never
    /// writes a sync token or encryption key, never contacts a server.
    func enterDemoMode() async {
        guard setupPhase == .needsConnection else {
            return
        }
        do {
            try await localFirstStore.openDemoBudget()
            let budget = DemoBudget.budget
            guard localFirstStore.isOpen(budgetID: budget.syncID) else {
                throw LocalFirstError.budgetNotOpened
            }
            settings.selectedBudgetID = budget.syncID
            settings.selectedBudgetName = DemoBudget.name
            settings.selectedLocalFirstFileID = DemoBudget.fileID
            settings.selectedLocalFirstGroupID = DemoBudget.groupID
            settings.backgroundTransactionRefreshEnabled = false
            settings.simplefinBackgroundSyncEnabled = false
            settings.pendingNewTransactionIDsByAccount = [:]
            updateApplicationBadge()
            budgets = [budget]
            selectedBudget = budget
            setupPhase = .ready
            connectionStatus = .offline
            lastErrorMessage = nil
            localDataRevision &+= 1
            settingsStore.save(settings)
        } catch {
            lastErrorMessage = error.localizedDescription
            connectionStatus = .offline
        }
    }

    var isReadyForMainTabs: Bool {
        guard setupPhase == .ready,
              let selectedBudgetID = settings.selectedBudgetID,
              selectedBudget?.syncID == selectedBudgetID else {
            return false
        }
        if isBudgetSwitchInProgress {
            return true
        }
        return localFirstStore.isOpen(budgetID: selectedBudgetID)
    }

    func loadLocalFirstLoginMethods(
        serverURLString: String
    ) async -> ActualLoginMethodsResponse? {
        let normalized = ActualServerURLNormalizer.normalize(serverURLString)
        guard !normalized.isEmpty else {
            lastErrorMessage = LocalFirstError.missingServerURL.localizedDescription
            return nil
        }
        if let blockedMessage = ActualServerConnectionSecurity.blockedMessage(for: normalized) {
            lastErrorMessage = blockedMessage
            return nil
        }

        do {
            let response = try await localFirstStore.loginMethods(serverURLString: normalized)
            lastErrorMessage = nil
            return response
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    func saveLocalFirstConnection(serverURLString: String, password: String) async -> Bool {
        await saveLocalFirstConnection(serverURLString: serverURLString) { normalized, targetBudgetID in
            try await self.localFirstStore.stageConnection(
                serverURLString: normalized,
                password: password,
                selectedBudgetID: targetBudgetID
            )
        }
    }

    func saveLocalFirstOpenIDConnection(
        serverURLString: String,
        browserSession: @escaping ActualOpenIDBrowserSession
    ) async -> Bool {
        await saveLocalFirstConnection(serverURLString: serverURLString) { normalized, targetBudgetID in
            try await self.localFirstStore.stageOpenIDConnection(
                serverURLString: normalized,
                selectedBudgetID: targetBudgetID,
                browserSession: browserSession
            )
        }
    }

    private func saveLocalFirstConnection(
        serverURLString: String,
        stage: (String, String?) async throws -> StagedLocalFirstConnection
    ) async -> Bool {
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
            let staged = try await stage(normalized, targetBudgetID)
            if let targetBudgetID,
               let target = staged.budgets.first(where: { $0.syncID == targetBudgetID }) {
                try await localFirstStore.validateCachedBudgetCanOpen(target)
            }

            try localFirstStore.commitConnection(staged)
            settings.localFirstServerURLString = normalized
            budgets = AppBudgetList.unique(staged.budgets)
            if serverChanged {
                settings.pendingNewTransactionIDsByAccount = [:]
                updateApplicationBadge()
                settings.backgroundTransactionRefreshEnabled = false
            settings.simplefinBackgroundSyncEnabled = false
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
                if localFirstStore.isOpen(budgetID: targetBudgetID) {
                    selectedBudget = target
                    setupPhase = .ready
                } else {
                    selectedBudget = nil
                    setupPhase = .selectingBudget
                }
            } else {
                setupPhase = .selectingBudget
            }
            if requiresReauthentication {
                localFirstStore.clearLastSyncError()
            }
            requiresReauthentication = false
            connectionStatus = .online
            lastErrorMessage = nil
            return true
        } catch ActualOpenIDAuthenticationError.cancelled {
            lastErrorMessage = nil
            return false
        } catch {
            lastErrorMessage = error.localizedDescription
            if previousServerURLString.isEmpty && !hasSyncCredentials {
                connectionStatus = .offline
                setupPhase = .needsConnection
            }
            return false
        }
    }

    func disconnectAndEraseLocalData() {
        do {
            appSyncCoordinator.cancelRefresh()
            try localFirstStore.eraseLocalData()
            settings.localFirstServerURLString = ""
            settings.fallbackServerURLString = ""
            localFirstStore.fallbackServerURLString = nil
            settings.selectedBudgetID = nil
            settings.selectedBudgetName = nil
            settings.selectedLocalFirstFileID = nil
            settings.selectedLocalFirstGroupID = nil
            settings.pendingNewTransactionIDsByAccount = [:]
            updateApplicationBadge()
            settings.backgroundTransactionRefreshEnabled = false
            settings.simplefinBackgroundSyncEnabled = false
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

    /// Updates the optional fallback server URL used when the primary server is
    /// unreachable (e.g. a Tailscale URL when away from home Wi-Fi). An empty
    /// string clears it. This does not affect the saved connection, sync token,
    /// or budget selection — the fallback is the same logical server reached via
    /// a different network path.
    func updateFallbackServerURL(_ serverURL: String) {
        let normalized = ActualServerURLNormalizer.normalize(serverURL)
        settings.fallbackServerURLString = normalized
        localFirstStore.fallbackServerURLString = normalized.isEmpty ? nil : normalized
        settingsStore.save(settings)
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

    var cachedSelectedBudgetMonth: LoadedBudgetMonth? {
        guard let budgetID = settings.selectedBudgetID else {
            return nil
        }
        return localFirstStore.cachedBudgetMonth(budgetID: budgetID)
    }

    func beginForegroundSession() async {
        guard appSyncCoordinator.beginForegroundSession() else {
            return
        }

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
        appSyncCoordinator.endForegroundSession()
    }

    @discardableResult
    func refreshLocalFirstData(budgetID: String, force: Bool = true) async -> Bool {
        guard localFirstStore.isOpen(budgetID: budgetID) else {
            return false
        }

        if isDemoMode {
            // Demo mode never syncs. Perform a local cache reload and report
            // success without flipping connection state or surfacing errors.
            _ = try? await localFirstStore.refresh(
                budgetID: budgetID,
                serverURLString: settings.localFirstServerURLString
            )
            localDataRevision &+= 1
            return true
        }

        let result = await appSyncCoordinator.refresh(
            budgetID: budgetID,
            serverURLString: settings.localFirstServerURLString,
            force: force,
            store: localFirstStore,
            onStart: { [weak self] in
                self?.connectionStatus = .connecting
            },
            isBudgetCurrent: { [weak self] in
                guard let self else { return false }
                return self.settings.selectedBudgetID == budgetID
                    && self.localFirstStore.isOpen(budgetID: budgetID)
            }
        )
        switch result.outcome {
        case .succeeded:
            if result.shouldPublish {
                connectionStatus = .online
                lastErrorMessage = nil
                localDataRevision &+= 1
            }
            return true
        case .alreadyRequested:
            return true
        case .cancelledOrStale:
            return false
        case .failed(let message, let requiresReauthentication):
            if result.shouldPublish {
                lastErrorMessage = message
                connectionStatus = .offline
                if requiresReauthentication {
                    self.requiresReauthentication = true
                }
            }
            return false
        }
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

    func reimportLocalFirstBudget() async {
        guard let budget = selectedBudget else {
            return
        }

        appSyncCoordinator.cancelRefresh()
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
        if encryptionPassword?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           localFirstStore.requiresEncryptionPasswordToOpen(budget) {
            lastErrorMessage = LocalFirstError.encryptedBudgetRequiresPassword.localizedDescription
            return
        }

        let previousBudget = selectedBudget
        let previousBudgetID = settings.selectedBudgetID
        let isChangingBudget = previousBudgetID != budget.syncID
        let canRestorePreviousBudget = isChangingBudget
            && setupPhase == .ready
            && previousBudget?.syncID == previousBudgetID
            && previousBudgetID.map { localFirstStore.isOpen(budgetID: $0) } == true

        if isChangingBudget {
            isBudgetSwitchInProgress = canRestorePreviousBudget
            appSyncCoordinator.cancelRefresh()
            localFirstStore.closeOpenBudget()
            accountNavigationPath = []
        }
        defer { isBudgetSwitchInProgress = false }

        connectionStatus = .connecting
        do {
            try await localFirstStore.openBudget(
                budget,
                serverURLString: settings.localFirstServerURLString,
                encryptionPassword: encryptionPassword
            )
            guard localFirstStore.isOpen(budgetID: budget.syncID) else {
                throw LocalFirstError.budgetNotOpened
            }
            selectedBudget = budget
            settings.selectedBudgetID = budget.syncID
            settings.selectedBudgetName = budget.name
            settings.selectedLocalFirstFileID = budget.localFirstFileID
            settings.selectedLocalFirstGroupID = budget.groupId
            settings.backgroundTransactionRefreshEnabled = false
            settings.simplefinBackgroundSyncEnabled = false
            settingsStore.save(settings)
            setupPhase = .ready
            connectionStatus = .online
            lastErrorMessage = nil
            localDataRevision &+= 1
        } catch {
            var restoredPreviousBudget = false
            if canRestorePreviousBudget, let previousBudget {
                localFirstStore.closeOpenBudget()
                restoredPreviousBudget = (try? await localFirstStore.openCachedBudget(previousBudget)) == true
            }
            lastErrorMessage = error.localizedDescription
            connectionStatus = .offline
            if restoredPreviousBudget {
                selectedBudget = previousBudget
                setupPhase = .ready
            } else if settings.selectedBudgetID.map({ localFirstStore.isOpen(budgetID: $0) }) != true {
                setupPhase = .selectingBudget
            }
        }
    }

    func clearSelectionForBudgetChange() {
        appSyncCoordinator.cancelRefresh()
        localFirstStore.reset()
        accountNavigationPath = []
        selectedBudget = nil
        settings.selectedBudgetID = nil
        settings.selectedBudgetName = nil
        settingsStore.save(settings)
        setupPhase = hasSyncCredentials ? .selectingBudget : .needsConnection
    }

    func beginReauthentication() {
        lastErrorMessage = nil
        setupPhase = .needsConnection
    }

    func cancelReauthentication() {
        lastErrorMessage = nil
        if let budgetID = settings.selectedBudgetID,
           localFirstStore.isOpen(budgetID: budgetID) {
            setupPhase = .ready
        } else {
            setupPhase = hasSyncCredentials ? .selectingBudget : .needsConnection
        }
    }

    var canCancelReauthentication: Bool {
        guard let budgetID = settings.selectedBudgetID else { return false }
        return localFirstStore.isOpen(budgetID: budgetID)
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

    func updateShowTotalAssigned(_ isEnabled: Bool) {
        settings.showTotalAssigned = isEnabled
        settingsStore.save(settings)
    }

    func updateHideCarryoverArrows(_ isHidden: Bool) {
        settings.hideCarryoverArrows = isHidden
        settingsStore.save(settings)
    }

    func updateShowHiddenCategories(_ isEnabled: Bool) {
        settings.showHiddenCategories = isEnabled
        settingsStore.save(settings)
    }

    func updateRandomizedDisplayValuesEnabled(_ isEnabled: Bool) {
        settings.randomizedDisplayValuesEnabled = isEnabled
        settingsStore.save(settings)
    }

    func updateShortcutsEnabled(_ isEnabled: Bool) {
        settings.shortcutsEnabled = isEnabled
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
        settings.isExperimentalFeatureEnabled(feature)
    }

    func updateExperimentalFeature(_ feature: ExperimentalFeature, isEnabled: Bool) {
        if isEnabled {
            settings.enabledExperimentalFeatures.insert(feature)
        } else {
            settings.enabledExperimentalFeatures.remove(feature)
            if feature == .bankSync {
                settings.simplefinBackgroundSyncEnabled = false
            }
        }
        settingsStore.save(settings)
        if feature == .bankSync {
            BackgroundTransactionRefreshCoordinator.shared.cancelOrReschedule(for: self)
        }
    }

    func updateDeveloperModeUnlocked(_ isUnlocked: Bool) {
        settings.developerModeUnlocked = isUnlocked
        resetDeveloperUnlockProgress()
        settingsStore.save(settings)
    }

    func recordDeveloperUnlockTap() -> String? {
        guard !settings.developerModeUnlocked else {
            return nil
        }

        switch developerUnlockTracker.recordTap(at: Date()) {
        case .unlocked:
            updateDeveloperModeUnlocked(true)
            return "You're a developer!"
        case .hidden:
            return nil
        case .countdown(let remainingTaps):
            let noun = remainingTaps == 1 ? "tap" : "taps"
            return "\(remainingTaps) \(noun) from Developer Mode"
        }
    }

    func resetDeveloperUnlockProgress() {
        developerUnlockTracker.reset()
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

    func defaultAccountID(forBudgetID budgetID: String) -> String? {
        settings.defaultAccountIDByBudgetID[budgetID]
    }

    func setDefaultAccountID(_ accountID: String?, budgetID: String) {
        settings.defaultAccountIDByBudgetID[budgetID] = accountID
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
        let outcome = await backgroundTransactionWorkflow.enable(isEnabled, keychain: keychain)
        settings.backgroundTransactionRefreshEnabled = (outcome == .enabled)
        settingsStore.save(settings)
        switch outcome {
        case .enabled:
            BackgroundTransactionRefreshCoordinator.shared.scheduleIfNeeded(for: self)
        case .disabled, .authorizationDenied:
            BackgroundTransactionRefreshCoordinator.shared.cancelOrReschedule(for: self)
        case .credentialPromotionFailed(let message):
            lastErrorMessage = message
            BackgroundTransactionRefreshCoordinator.shared.cancelOrReschedule(for: self)
        }
    }

    /// Phase 6: enabling background bank sync promotes Keychain items for
    /// background access (like the alerts toggle) but never requests
    /// notification authorization — it posts nothing.
    func updateSimpleFINBackgroundSyncEnabled(_ isEnabled: Bool) async {
        let enable = isEnabled && isExperimentalFeatureEnabled(.bankSync)
        if enable {
            do {
                try keychain.promoteAllItemsForBackgroundRefresh()
            } catch {
                lastErrorMessage = error.localizedDescription
                settings.simplefinBackgroundSyncEnabled = false
                settingsStore.save(settings)
                BackgroundTransactionRefreshCoordinator.shared.cancelOrReschedule(for: self)
                return
            }
        }
        settings.simplefinBackgroundSyncEnabled = enable
        settingsStore.save(settings)
        if enable {
            BackgroundTransactionRefreshCoordinator.shared.scheduleIfNeeded(for: self)
        } else {
            BackgroundTransactionRefreshCoordinator.shared.cancelOrReschedule(for: self)
        }
    }

    func prepareBackgroundTransactionNotifications() async {
        await backgroundTransactionWorkflow.prepare(
            isEnabled: settings.backgroundTransactionRefreshEnabled,
            settings: settings
        )
    }

    func performBackgroundTransactionRefresh(
        timeLimit: Duration = .seconds(25)
    ) async -> Bool {
        let result = await backgroundTransactionWorkflow.performRefresh(
            timeLimit: timeLimit,
            isDemoMode: isDemoMode,
            settings: settings,
            selectedBudget: selectedBudget,
            budgets: budgets,
            hasSyncCredentials: hasSyncCredentials,
            store: localFirstStore
        )
        settings = result.settings
        switch result.outcome {
        case .success:
            return true
        case .skipped, .cancelled, .timedOut:
            return false
        case .failed(let message):
            lastErrorMessage = message
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
            guard let selectedBudgetID = settings.selectedBudgetID,
                  localFirstStore.isOpen(budgetID: selectedBudgetID) else {
                localFirstStore.reset()
                return false
            }
            selectedBudget = budget
            budgets = AppBudgetList.unique([budget] + budgets)
            setupPhase = .ready
            connectionStatus = restoredStatus
            localDataRevision &+= 1
            return true
        } catch {
            return false
        }
    }

    private func restoreSelectedBudgetForLaunch() async {
        let restoredStatus: ServerConnectionStatus = isDemoMode ? .offline : .connecting
        if await openSelectedCachedBudget(connectionStatus: restoredStatus) {
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
        backgroundTransactionWorkflow.recordScheduleAttempt(
            succeeded: succeeded,
            earliestBeginDate: earliestBeginDate,
            message: message,
            in: &settings
        )
    }

    func pendingNewTransactionIDs(budgetID: String, accountID: String) -> Set<String> {
        backgroundTransactionWorkflow.pendingNewTransactionIDs(
            budgetID: budgetID,
            accountID: accountID,
            in: settings
        )
    }

    func pendingNewTransactionIDs(budgetID: String) -> Set<String> {
        backgroundTransactionWorkflow.pendingNewTransactionIDs(
            budgetID: budgetID,
            in: settings
        )
    }

    func clearPendingNewTransactionIDs(budgetID: String, accountID: String) {
        backgroundTransactionWorkflow.clearPendingNewTransactionIDs(
            budgetID: budgetID,
            accountID: accountID,
            in: &settings
        )
    }

    func clearPendingNewTransactionIDs(budgetID: String) {
        backgroundTransactionWorkflow.clearPendingNewTransactionIDs(
            budgetID: budgetID,
            in: &settings
        )
    }

    @discardableResult
    func updateApplicationBadge() -> Int {
        backgroundTransactionWorkflow.updateApplicationBadge(in: settings)
    }

    func routeToSpendingFromNotification(budgetID _: String) async {
        accountNavigationPath = []
        selectedTab = .spending
        routeCoordinator.enqueue(.tab(.spending))
    }

    #if DEBUG
    func setBudgetSwitchInProgressForTesting(_ isInProgress: Bool) {
        isBudgetSwitchInProgress = isInProgress
    }

    func postDebugNewTransactionNotification() async throws {
        guard let budgetID = settings.selectedBudgetID else {
            throw DebugNotificationError.missingBudget
        }
        try await backgroundTransactionWorkflow.postDebugNotification(
            budgetID: budgetID,
            repository: accountRepository
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
            budgets = AppBudgetList.unique(
                try await localFirstStore.loadBudgets(serverURLString: settings.localFirstServerURLString)
            )

            if budgets.count == 1, let budget = budgets.first, settings.selectedBudgetID == nil {
                await selectLocalFirstBudget(budget)
                return
            }

            if let selectedBudgetID = settings.selectedBudgetID,
               let budget = budgets.first(where: { $0.syncID == selectedBudgetID }) {
                selectedBudget = budget
                // Reopening here would race the normal refresh path.
                if !localFirstStore.isOpen(budgetID: selectedBudgetID) {
                    try await localFirstStore.openBudget(
                        budget,
                        serverURLString: settings.localFirstServerURLString
                    )
                }
                guard localFirstStore.isOpen(budgetID: selectedBudgetID) else {
                    setupPhase = .selectingBudget
                    connectionStatus = .online
                    return
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
            if (error as? ActualAPIError)?.isAuthenticationFailure == true {
                requiresReauthentication = true
            }
            if settings.selectedBudgetID == nil {
                setupPhase = .needsConnection
            }
            throw error
        }
    }

    var budgetRepository: any BudgetRepositoryProtocol { localFirstStore }
    var transactionRepository: any TransactionRepositoryProtocol { localFirstStore }
    var accountRepository: any AccountRepositoryProtocol { localFirstStore }
    var payeeRepository: any PayeeRepositoryProtocol { localFirstStore }
    var ruleRepository: any RuleRepositoryProtocol { localFirstStore }
    var reportsRepository: any ReportsRepositoryProtocol { localFirstStore }

    func recordLocalDataMutation() {
        localDataRevision &+= 1
    }

}
