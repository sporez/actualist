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
    let routeCoordinator = AppRouteCoordinator()

    let settingsStore: AppSettingsStore
    let keychain: KeychainStore
    private let credentialRetryPreparation: @MainActor () -> Void
    private let widgetSnapshotClearer: @MainActor () -> Void
    @ObservationIgnored private let sessionRecovery = AppSessionRecovery()
    @ObservationIgnored private let appSyncCoordinator = AppSyncCoordinator()
    @ObservationIgnored private let launchWarmupCoordinator = LaunchWarmupCoordinator()
    @ObservationIgnored let backgroundTransactionWorkflow: BackgroundTransactionWorkflow
    @ObservationIgnored private let providedLocalFirstStore: LocalFirstActualStore?
    private var developerUnlockTracker = DeveloperUnlockTracker()

    var backgroundSessionIdentity: BackgroundTransactionWorkflow.SessionIdentity {
        backgroundTransactionWorkflow.sessionIdentity(
            settings: settings,
            recoveryIdentity: sessionRecovery.identity
        )
    }

    @ObservationIgnored lazy var localFirstStore: LocalFirstActualStore = {
        let store = providedLocalFirstStore ?? LocalFirstActualStore(
            keychain: keychain,
            syncDebugRecorder: { [weak self] event in
                self?.recordLocalFirstSyncDebugEvent(event)
            }
        )
        store.fallbackServerURLString = ActualServerConnectionSecurity.usableFallback(
            settings.fallbackServerURLString
        )
        return store
    }()

    init(
        settingsStore: AppSettingsStore = .live,
        keychain: KeychainStore = .actualist,
        localFirstStore: LocalFirstActualStore? = nil,
        credentialRetryPreparation: @escaping @MainActor () -> Void = {},
        notificationAuthorizationRequester: @escaping @MainActor () async throws -> Bool = {
            try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
        },
        applicationBadgeUpdater: @escaping @MainActor (Int) -> Void = { badgeCount in
            Task {
                try? await UNUserNotificationCenter.current().setBadgeCount(badgeCount)
            }
        },
        widgetSnapshotClearer: @escaping @MainActor () -> Void = { WidgetSnapshotCoordinator.shared.clearSnapshot() }
    ) {
        self.settingsStore = settingsStore
        self.keychain = keychain
        self.credentialRetryPreparation = credentialRetryPreparation
        self.widgetSnapshotClearer = widgetSnapshotClearer
        self.backgroundTransactionWorkflow = BackgroundTransactionWorkflow(
            settingsStore: settingsStore,
            notificationAuthorizationRequester: notificationAuthorizationRequester,
            applicationBadgeUpdater: applicationBadgeUpdater
        )
        self.providedLocalFirstStore = localFirstStore
        let loaded = settingsStore.load()
        self.settings = loaded
        ActualistTheme.activate(loaded.theme)
        let (phase, status) = sessionRecovery.initialSession(settings: loaded, keychain: keychain)
        self.setupPhase = phase
        self.connectionStatus = status
    }

    var hasSyncCredentials: Bool {
        !settings.localFirstServerURLString.isEmpty && credentialAvailability == .available
    }

    /// Cached by `AppSessionRecovery` so SwiftUI bodies never read Keychain.
    /// The fallback read is only reachable before the initial refresh.
    var credentialAvailability: AppSessionRecovery.CredentialAvailability {
        sessionRecovery.cachedCredentialAvailability
            ?? AppSessionRecovery.credentialAvailability(keychain: keychain)
    }

    func refreshCredentialAvailability() {
        sessionRecovery.refreshCredentialAvailability(keychain: keychain)
    }

    var credentialRecoveryMessage: String? { sessionRecovery.message }
    var budgetSessionTransitions: BudgetSessionTransitionCoordinator { sessionRecovery.transitions }

    func retryCredentialAccess() async {
        credentialRetryPreparation()
        let hadOpenBudget = isReadyForMainTabs
        let action = sessionRecovery.retry(
            keychain: keychain,
            hasOpenBudget: hadOpenBudget,
            hasSelection: settings.selectedBudgetID != nil
        )
        if !hadOpenBudget { localFirstStore.closeOpenBudget() }
        switch action {
        case .unavailable(let message): lastErrorMessage = message
        case .needsConnection:
            if !isReadyForMainTabs { setupPhase = .needsConnection }
        case .refresh:
            lastErrorMessage = nil
            if let budgetID = settings.selectedBudgetID {
                _ = await refreshLocalFirstData(budgetID: budgetID)
            }
        case .restore:
            setupPhase = .restoringBudget
            await restoreSelectedBudgetForLaunch()
        case .discover:
            _ = try? await loadBudgets() // loadBudgets publishes the failure.
        }
    }

    /// `true` when the selected budget is the bundled demo budget. Derived from
    /// the persisted selection so launch restore and erase work for demo with
    /// no new settings keys. Presentation and store guards key off this.
    var isDemoMode: Bool {
        DemoBudget.isReservedFileID(settings.selectedLocalFirstFileID)
    }

    /// Install and open the bundled demo budget, then route straight to the
    /// main app shell. Only valid from `.needsConnection` (onboarding). Never
    /// writes a sync token or encryption key, never contacts a server.
    func enterDemoMode(tracking: Bool = false) async {
        guard setupPhase == .needsConnection else { return }
        _ = await budgetSessionTransitions.run(.demo, budgetID: DemoBudget.budget.syncID) { [self] in
            do {
                try await localFirstStore.openDemoBudget(tracking: tracking)
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
                lastErrorMessage = error.userFacingMessage
                connectionStatus = .offline
            }
        }
    }

    var isReadyForMainTabs: Bool {
        guard setupPhase == .ready,
              let selectedBudgetID = settings.selectedBudgetID,
              selectedBudget?.syncID == selectedBudgetID else {
            return false
        }
        // A switch keeps the current budget's tabs until the replacement opens.
        return budgetSessionTransitions.keepsShell || localFirstStore.isOpen(budgetID: selectedBudgetID)
    }

    func loadLocalFirstLoginMethods(
        serverURLString: String
    ) async -> ActualLoginMethodsResponse? {
        let normalized = ActualServerURLNormalizer.normalize(serverURLString)
        guard !normalized.isEmpty else {
            lastErrorMessage = LocalFirstError.missingServerURL.localizedDescription
            return nil
        }
        if let rejection = ActualServerConnectionSecurity.rejection(for: normalized) {
            lastErrorMessage = rejection
            return nil
        }

        do {
            let response = try await localFirstStore.loginMethods(serverURLString: normalized)
            lastErrorMessage = nil
            return response
        } catch {
            lastErrorMessage = error.userFacingMessage
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
        if let rejection = ActualServerConnectionSecurity.rejection(for: normalized) {
            lastErrorMessage = rejection
            return false
        }

        let previousServerURLString = settings.localFirstServerURLString
        let serverChanged = !previousServerURLString.isEmpty && previousServerURLString != normalized
        let targetBudgetID = serverChanged ? nil : settings.selectedBudgetID
        let recoveryIdentity = sessionRecovery.identity
        var activeIdentity = recoveryIdentity

        do {
            let staged = try await stage(normalized, targetBudgetID)
            guard sessionRecovery.isCurrent(recoveryIdentity) else { return false }
            var canRestoreTargetBudget = false
            if let targetBudgetID,
               let target = staged.budgets.first(where: { $0.syncID == targetBudgetID }) {
                canRestoreTargetBudget = try await localFirstStore.validateCachedBudgetCanOpen(target)
                guard sessionRecovery.isCurrent(recoveryIdentity) else { return false }
            }

            try localFirstStore.commitConnection(staged)
            refreshCredentialAvailability()
            sessionRecovery.invalidate()
            activeIdentity = sessionRecovery.identity
            settings.localFirstServerURLString = normalized
            budgets = AppBudgetList.unique(staged.budgets)
            if serverChanged {
                settings.pendingNewTransactionIDsByAccount = [:]
                updateApplicationBadge()
                settings.backgroundTransactionRefreshEnabled = false
                settings.simplefinBackgroundSyncEnabled = false
                localFirstStore.reset()
                localFirstStore.remoteFilesByFileID = staged.remoteFilesByFileID
                localFirstStore.cachedBudgets = staged.budgets
            }
            if serverChanged || (targetBudgetID != nil && !canRestoreTargetBudget) {
                settings.selectedBudgetID = nil
                settings.selectedBudgetName = nil
                settings.selectedLocalFirstFileID = nil
                settings.selectedLocalFirstGroupID = nil
                accountNavigationPath = []
                routeCoordinator.reset()
                selectedBudget = nil
            }
            settingsStore.save(settings)

            if canRestoreTargetBudget,
               let targetBudgetID,
               let target = budgets.first(where: { $0.syncID == targetBudgetID }) {
                if !localFirstStore.isOpen(budgetID: targetBudgetID) {
                    _ = try await localFirstStore.openCachedBudget(
                        target, expectedGeneration: localFirstStore.budgetSessionGeneration
                    )
                    guard sessionRecovery.isCurrent(activeIdentity) else { return false }
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
        } catch where error.isCancellation {
            if sessionRecovery.isCurrent(activeIdentity) { lastErrorMessage = nil }
            return false
        } catch {
            guard sessionRecovery.isCurrent(activeIdentity) else { return false }
            lastErrorMessage = error.userFacingMessage
            if previousServerURLString.isEmpty && !hasSyncCredentials {
                connectionStatus = .offline
                setupPhase = .needsConnection
            }
            return false
        }
    }

    func disconnectAndEraseLocalData() {
        do {
            sessionRecovery.invalidate()
            budgetSessionTransitions.cancel()
            appSyncCoordinator.cancelRefresh()
            widgetSnapshotClearer()
            try localFirstStore.eraseLocalData()
            refreshCredentialAvailability()
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
            routeCoordinator.reset()
            setupPhase = .needsConnection
            connectionStatus = .offline
            lastErrorMessage = nil
            localDataRevision &+= 1
            BackgroundTransactionRefreshCoordinator.shared.cancel()
        } catch {
            lastErrorMessage = error.userFacingMessage
            connectionStatus = .offline
        }
    }

    var localFirstSyncStatus: LocalFirstSyncStatus? {
        guard let budgetID = settings.selectedBudgetID else {
            return nil
        }
        return localFirstStore.syncStatus(budgetID: budgetID)
    }

    func beginForegroundSession() async {
        guard appSyncCoordinator.beginForegroundSession() else {
            return
        }
        launchWarmupCoordinator.beginForeground(appState: self)
        refreshCredentialAvailability()

        if setupPhase == .restoringBudget {
            await LaunchSignpost.measure(LaunchStage.cachedBudgetRestore) {
                await restoreSelectedBudgetForLaunch()
            }
        } else if sessionRecovery.state != .idle {
            await retryCredentialAccess()
        }
    }

    @discardableResult
    func budgetDidPresent(_ budgetID: String?) -> Task<Void, Never>? {
        guard let budgetID else {
            WidgetSnapshotCoordinator.shared.endFinancialPublication()
            launchWarmupCoordinator.endPresentation()
            return nil
        }
        guard setupPhase == .ready, settings.selectedBudgetID == budgetID,
              localFirstStore.isOpen(budgetID: budgetID) else { return nil }
        WidgetSnapshotCoordinator.shared.beginFinancialPublication()
        return launchWarmupCoordinator.present(budgetID: budgetID, appState: self)
    }

    func endForegroundSession() {
        launchWarmupCoordinator.endForeground()
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
                sessionRecovery.clear()
                localDataRevision &+= 1
            }
            return true
        case .alreadyRequested:
            return true
        case .cancelledOrStale:
            return false
        case .failed(let message, let reason):
            if result.shouldPublish {
                lastErrorMessage = message
                connectionStatus = reason.connectionStatus
                if case .credentialUnavailable(let error) = reason {
                    sessionRecovery.noteFailure(error, hasOpenBudget: true)
                }
                if reason == .authenticationRequired {
                    requiresReauthentication = true
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

    @discardableResult
    func reimportLocalFirstBudget(encryptionPassword: String? = nil) async -> BudgetOpenOutcome {
        guard let budget = selectedBudget else {
            return .superseded
        }

        switch await budgetSessionTransitions.run(.reimport, budgetID: budget.syncID, operation: { [self] in
            appSyncCoordinator.cancelRefresh()
            connectionStatus = .connecting
            return await sessionRecovery.reimport(
                budget, serverURLString: settings.localFirstServerURLString,
                encryptionPassword: encryptionPassword, store: localFirstStore
            )
        }) {
        case nil: return .busy
        case .succeeded:
            connectionStatus = .online
            lastErrorMessage = nil
            localDataRevision &+= 1
            return .opened
        case .failed(let error, let status):
            connectionStatus = status
            return recordOpenFailure(error)
        case .superseded:
            return .superseded
        }
    }

    /// Publishes a failed open and classifies it. A missing encryption
    /// password is a prompt, not an error banner.
    private func recordOpenFailure(_ error: Error) -> BudgetOpenOutcome {
        if case LocalFirstError.encryptedBudgetRequiresPassword = error {
            lastErrorMessage = nil
            return .needsEncryptionPassword
        }
        lastErrorMessage = error.userFacingMessage
        return .failed(message: lastErrorMessage)
    }

    @discardableResult
    func selectBudgetForCurrentBackend(
        _ budget: ActualBudget, encryptionPassword: String? = nil
    ) async -> BudgetOpenOutcome {
        do {
            if encryptionPassword?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               try localFirstStore.requiresEncryptionPasswordToOpen(budget) {
                lastErrorMessage = nil
                return .needsEncryptionPassword
            }
        } catch {
            sessionRecovery.noteFailure(error, hasOpenBudget: isReadyForMainTabs)
            return recordOpenFailure(error)
        }
        let keepsShell = settings.selectedBudgetID != budget.syncID && canRestoreSelectedBudget
        return await budgetSessionTransitions.run(.select, budgetID: budget.syncID, keepsShell: keepsShell) { [self] in
            await openSelection(budget, encryptionPassword: encryptionPassword)
        } ?? .busy
    }

    private var canRestoreSelectedBudget: Bool {
        setupPhase == .ready && selectedBudget?.syncID == settings.selectedBudgetID
            && settings.selectedBudgetID.map { localFirstStore.isOpen(budgetID: $0) } == true
    }

    private func openSelection(_ budget: ActualBudget, encryptionPassword: String?) async -> BudgetOpenOutcome {
        sessionRecovery.invalidate()
        let previousBudget = selectedBudget
        let isChangingBudget = settings.selectedBudgetID != budget.syncID
        let canRestorePreviousBudget = isChangingBudget && canRestoreSelectedBudget
        if isChangingBudget {
            appSyncCoordinator.cancelRefresh()
            localFirstStore.closeOpenBudget()
            accountNavigationPath = []
        }

        connectionStatus = .connecting
        switch await sessionRecovery.openSelectedBudget(
            budget, serverURLString: settings.localFirstServerURLString,
            encryptionPassword: encryptionPassword, previousBudget: previousBudget,
            canRestorePreviousBudget: canRestorePreviousBudget, store: localFirstStore
        ) {
        case .opened(let credentialError):
            selectedBudget = budget
            settings.selectedBudgetID = budget.syncID
            settings.selectedBudgetName = budget.name
            settings.selectedLocalFirstFileID = budget.localFirstFileID
            settings.selectedLocalFirstGroupID = budget.groupId
            settings.backgroundTransactionRefreshEnabled = false
            settings.simplefinBackgroundSyncEnabled = false
            settingsStore.save(settings)
            setupPhase = .ready
            (connectionStatus, lastErrorMessage) = sessionRecovery.openedBudgetStatus(
                keychain: keychain, credentialError: credentialError
            )
            localDataRevision &+= 1
            return .opened
        case .restored(let error):
            let outcome = recordOpenFailure(error)
            sessionRecovery.noteFailure(error, hasOpenBudget: true)
            connectionStatus = .offline
            selectedBudget = previousBudget
            setupPhase = .ready
            return outcome
        case .failed(let error):
            let outcome = recordOpenFailure(error)
            sessionRecovery.noteFailure(error, hasOpenBudget: localFirstStore.hasOpenBudget)
            connectionStatus = .offline
            if settings.selectedBudgetID.map({ localFirstStore.isOpen(budgetID: $0) }) != true {
                setupPhase = .selectingBudget
            }
            return outcome
        case .superseded: return .superseded
        }
    }

    func beginReauthentication() {
        lastErrorMessage = nil
        // Leaving .ready tears down the settings host; drop its stale route state.
        routeCoordinator.reset()
        setupPhase = .needsConnection
    }

    func cancelReauthentication() {
        lastErrorMessage = nil
        setupPhase = sessionRecovery.phaseAfterCancelingReauthentication(
            selectedBudgetID: settings.selectedBudgetID, store: localFirstStore, keychain: keychain
        )
    }

    var canCancelReauthentication: Bool {
        guard let budgetID = settings.selectedBudgetID else { return false }
        return localFirstStore.isOpen(budgetID: budgetID)
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

    private func restoreSelectedBudgetForLaunch() async {
        let identity = sessionRecovery.identity
        switch await sessionRecovery.restoreForLaunch(
            settings: settings, keychain: keychain, store: localFirstStore, isDemoMode: isDemoMode
        ) {
        case .opened(let budget, let status):
            selectedBudget = budget
            budgets = AppBudgetList.unique([budget] + budgets)
            setupPhase = .ready
            LaunchSignpost.event(LaunchStage.setupReady)
            connectionStatus = status
            lastErrorMessage = sessionRecovery.message
            localDataRevision &+= 1
        case .discovered(let discovery):
            await presentDiscoveredBudgets(discovery, identity: identity)
        case .blocked(let error):
            setupPhase = .credentialUnavailable
            lastErrorMessage = error.localizedDescription
        case .needsConnection:
            setupPhase = .needsConnection
            connectionStatus = .offline
        case .failed(let error):
            lastErrorMessage = error.userFacingMessage
            connectionStatus = .offline
            setupPhase = settings.selectedBudgetID == nil ? .needsConnection : .selectingBudget
        case .superseded: break
        }
    }

    func loadBudgets() async throws {
        let discoveryIdentity = sessionRecovery.identity
        do {
            let discovery = try await sessionRecovery.discoverBudgets(settings: settings, store: localFirstStore)
            guard sessionRecovery.isCurrent(discoveryIdentity) else { throw CancellationError() }
            await presentDiscoveredBudgets(discovery, identity: discoveryIdentity)
        } catch {
            guard sessionRecovery.isCurrent(discoveryIdentity) else { throw error }
            if error.isCancellation { throw error }
            lastErrorMessage = error.userFacingMessage
            connectionStatus = .offline
            if let phase = sessionRecovery.discoveryFailure(
                error, hasOpenBudget: isReadyForMainTabs, hasSelection: settings.selectedBudgetID != nil
            ) { setupPhase = phase }
            if (error as? ActualAPIError)?.isAuthenticationFailure == true {
                requiresReauthentication = true
            }
            throw error
        }
    }

    private func presentDiscoveredBudgets(
        _ discovery: AppSessionRecovery.BudgetDiscovery,
        identity: Int
    ) async {
        guard !Task.isCancelled, sessionRecovery.isCurrent(identity) else { return }
        budgets = discovery.budgets
        if budgets.count == 1, let budget = budgets.first, settings.selectedBudgetID == nil {
            _ = await selectBudgetForCurrentBackend(budget)
        } else if let budget = discovery.selectedBudget {
            selectedBudget = budget
            setupPhase = discovery.selectedIsOpen ? .ready : .selectingBudget
            if discovery.selectedIsOpen {
                (connectionStatus, lastErrorMessage) = sessionRecovery.openedBudgetStatus(
                    keychain: keychain, credentialError: discovery.credentialError
                )
            } else {
                connectionStatus = .online
            }
        } else {
            connectionStatus = .online
            setupPhase = .selectingBudget
        }
    }

}
