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

    private let settingsStore: AppSettingsStore
    private let keychain: KeychainStore
    private let snapshotStore: OfflineSnapshotStore
    private var activeNetworkRequestCount = 0

    /// In-memory source of truth for fetched API data (stale-while-revalidate cache).
    @ObservationIgnored lazy var dataStore = ActualDataStore(
        clientProvider: { [weak self] in self?.makeClient() },
        snapshotDidChange: { [weak self] in
            Task { @MainActor in self?.persistCurrentSnapshot() }
        },
        networkDidStart: { [weak self] in
            Task { @MainActor in self?.beginNetworkRequest() }
        },
        networkDidSucceed: { [weak self] in
            Task { @MainActor in self?.finishNetworkRequest(succeeded: true) }
        },
        networkDidFail: { [weak self] error in
            Task { @MainActor in self?.finishNetworkRequest(succeeded: false, error: error) }
        }
    )

    init(
        settingsStore: AppSettingsStore = .live,
        keychain: KeychainStore = .actualist,
        snapshotStore: OfflineSnapshotStore = .live
    ) {
        self.settingsStore = settingsStore
        self.keychain = keychain
        self.snapshotStore = snapshotStore
        let loaded = settingsStore.load()
        self.settings = loaded
        ActualistTheme.activate(loaded.theme)
        if loaded.serverURLString.isEmpty || keychain.readAPIKey().isEmpty || loaded.selectedBudgetID == nil {
            self.setupPhase = .needsConnection
            self.connectionStatus = .offline
        } else {
            self.setupPhase = .ready
            self.connectionStatus = .connecting
            restorePersistedSnapshot()
        }
    }

    var apiKey: String {
        keychain.readAPIKey()
    }

    var canUseAPI: Bool {
        !settings.serverURLString.isEmpty && !apiKey.isEmpty
    }

    var isReadOnly: Bool {
        setupPhase == .ready && connectionStatus == .offline
    }

    func saveConnection(serverURLString: String, apiKey: String) {
        settings.serverURLString = ServerURLNormalizer.normalize(serverURLString)
        settings.pendingNewTransactionIDsByAccount = [:]
        settingsStore.save(settings)
        keychain.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        // Credentials/server changed: never let another context's data linger.
        dataStore.reset()
        accountNavigationPath = []
        connectionStatus = .connecting
    }

    func selectBudget(_ budget: ActualBudget) {
        if settings.selectedBudgetID != budget.syncID {
            dataStore.reset()
            accountNavigationPath = []
        }
        selectedBudget = budget
        settings.selectedBudgetID = budget.syncID
        settings.selectedBudgetName = budget.name
        settingsStore.save(settings)
        setupPhase = .ready
        persistCurrentSnapshot()
        BackgroundTransactionRefreshCoordinator.shared.scheduleIfNeeded(for: self)
    }

    func clearSelectionForBudgetChange() {
        dataStore.reset()
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

    func updateTheme(_ theme: ActualistThemeOption) {
        settings.theme = theme
        ActualistTheme.activate(theme)
        themeRevision += 1
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

        guard settings.backgroundTransactionRefreshEnabled,
              setupPhase == .ready,
              let budgetID = settings.selectedBudgetID,
              makeClient() != nil else {
            recordBackgroundRefreshCompletion(
                runID: debugRunID,
                success: true,
                message: "Skipped: background alerts are disabled or the app is not ready"
            )
            return true
        }

        do {
            try await dataStore.refreshAccounts(budgetID: budgetID)
            let accounts = dataStore.accountsByBudget[budgetID]?.value ?? []
            let linkedAccounts = accounts.filter { $0.bankSyncLinked && !$0.closed }
            var newTransactionCount = 0

            for account in linkedAccounts {
                let result = try await dataStore.syncBankAccountAndFindNewTransactions(
                    budgetID: budgetID,
                    account: account
                )
                guard !result.newTransactionIDs.isEmpty else {
                    continue
                }

                recordPendingNewTransactionIDs(
                    result.newTransactionIDs,
                    budgetID: budgetID,
                    accountID: account.id
                )
                try await postNewTransactionsNotification(
                    account: account,
                    budgetID: budgetID,
                    count: result.newTransactionIDs.count
                )
                newTransactionCount += result.newTransactionIDs.count
            }

            persistCurrentSnapshot()
            recordBackgroundRefreshCompletion(
                runID: debugRunID,
                success: true,
                message: "Checked \(linkedAccounts.count) linked accounts; found \(newTransactionCount) new transactions"
            )
            return true
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

    func pendingNewTransactionIDs(budgetID: String, accountID: String) -> Set<String> {
        Set(settings.pendingNewTransactionIDsByAccount[pendingNewTransactionKey(budgetID: budgetID, accountID: accountID)] ?? [])
    }

    func clearPendingNewTransactionIDs(budgetID: String, accountID: String) {
        let key = pendingNewTransactionKey(budgetID: budgetID, accountID: accountID)
        guard settings.pendingNewTransactionIDsByAccount[key] != nil else {
            return
        }
        settings.pendingNewTransactionIDsByAccount[key] = nil
        settingsStore.save(settings)
    }

    func routeToAccountFromNotification(budgetID: String, accountID: String) async {
        selectedTab = .accounts
        guard settings.selectedBudgetID == budgetID else {
            accountNavigationPath = []
            return
        }

        if dataStore.accountsByBudget[budgetID]?.value == nil {
            try? await dataStore.refreshAccountsWithBalances(budgetID: budgetID)
        }

        let displays = dataStore.accountDisplays(budgetID: budgetID)
        guard let account = displays.first(where: { $0.account.id == accountID })?.account else {
            accountNavigationPath = []
            return
        }
        accountNavigationPath = [account]
    }

    func loadBudgets() async {
        guard makeClient() != nil else {
            connectionStatus = .offline
            if useOfflineSnapshotIfAvailable() {
                setupPhase = .ready
            } else {
                setupPhase = .needsConnection
            }
            return
        }

        do {
            try await dataStore.ensureBudgets()
            budgets = Self.uniqueBudgets(dataStore.budgets?.value ?? [])
            if budgets.count == 1, let budget = budgets.first {
                selectBudget(budget)
                return
            }

            if let selectedBudgetID = settings.selectedBudgetID,
               let budget = budgets.first(where: { $0.syncID == selectedBudgetID }) {
                selectedBudget = budget
                setupPhase = .ready
                return
            }

            setupPhase = .selectingBudget
        } catch {
            lastErrorMessage = error.localizedDescription
            connectionStatus = .offline
            if useOfflineSnapshotIfAvailable() {
                setupPhase = .ready
            } else {
                setupPhase = .needsConnection
            }
        }
    }

    func makeClient() -> ActualAPIClient? {
        let normalizedURLString = ServerURLNormalizer.normalize(settings.serverURLString)
        if normalizedURLString != settings.serverURLString {
            settings.serverURLString = normalizedURLString
            settingsStore.save(settings)
        }

        guard let baseURL = URL(string: normalizedURLString), !apiKey.isEmpty else {
            return nil
        }

        return ActualAPIClient(baseURL: baseURL, apiKey: apiKey)
    }

    /// Returns the shared data store as a budget repository, or `nil` when the app is not yet
    /// configured (so callers skip loading just as before).
    func makeBudgetRepository() -> (any BudgetRepositoryProtocol)? {
        guard makeClient() != nil else {
            return nil
        }

        return dataStore
    }

    func makeTransactionRepository() -> (any TransactionRepositoryProtocol)? {
        guard makeClient() != nil else {
            return nil
        }

        return dataStore
    }

    func cacheAccountsForOfflineUse() async {
        guard let budgetID = settings.selectedBudgetID else {
            return
        }

        try? await dataStore.refreshAccountsWithBalances(budgetID: budgetID)
    }

    private func restorePersistedSnapshot() {
        guard let budgetID = settings.selectedBudgetID,
              let snapshot = snapshotStore.load(
                serverURLString: settings.serverURLString,
                budgetID: budgetID
              ) else {
            return
        }

        dataStore.restore(snapshot)
        budgets = Self.uniqueBudgets(snapshot.budgets?.value ?? [])
        if let selected = budgets.first(where: { $0.syncID == budgetID }) {
            selectedBudget = selected
        } else if let selectedBudgetName = settings.selectedBudgetName {
            selectedBudget = ActualBudget(
                budgetID: budgetID,
                cloudFileId: nil,
                groupId: nil,
                name: selectedBudgetName,
                state: nil
            )
        }
    }

    private func persistCurrentSnapshot() {
        guard let budgetID = settings.selectedBudgetID,
              !settings.serverURLString.isEmpty,
              dataStore.hasCachedBudgetData(budgetID: budgetID) else {
            return
        }

        snapshotStore.save(
            dataStore.snapshot(),
            serverURLString: settings.serverURLString,
            budgetID: budgetID
        )
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
        account: ActualAccount,
        budgetID: String,
        count: Int
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = account.name
        content.body = count == 1 ? "1 new transaction" : "\(count) new transactions"
        content.sound = .default
        content.userInfo = [
            "budgetID": budgetID,
            "accountID": account.id
        ]

        let request = UNNotificationRequest(
            identifier: "actualist.new-transactions.\(budgetID).\(account.id).\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        try await UNUserNotificationCenter.current().add(request)
    }

    private func useOfflineSnapshotIfAvailable() -> Bool {
        if let budgetID = settings.selectedBudgetID,
           dataStore.hasCachedBudgetData(budgetID: budgetID) {
            budgets = Self.uniqueBudgets(dataStore.budgets?.value ?? budgets)
            if selectedBudget == nil, let selected = budgets.first(where: { $0.syncID == budgetID }) {
                selectedBudget = selected
            }
            return true
        }

        restorePersistedSnapshot()
        guard let budgetID = settings.selectedBudgetID else {
            return false
        }
        return dataStore.hasCachedBudgetData(budgetID: budgetID)
    }

    private func beginNetworkRequest() {
        activeNetworkRequestCount += 1
        connectionStatus = .connecting
    }

    private func finishNetworkRequest(succeeded: Bool, error: Error? = nil) {
        activeNetworkRequestCount = max(0, activeNetworkRequestCount - 1)
        if succeeded {
            if activeNetworkRequestCount == 0 {
                connectionStatus = .online
                lastErrorMessage = nil
            }
        } else {
            lastErrorMessage = error?.localizedDescription
            if error.isConnectivityFailure {
                connectionStatus = .offline
            } else if activeNetworkRequestCount == 0 {
                connectionStatus = .online
            }
        }
    }

    private static func uniqueBudgets(_ budgets: [ActualBudget]) -> [ActualBudget] {
        var seenSyncIDs: Set<String> = []
        return budgets.filter { budget in
            seenSyncIDs.insert(budget.syncID).inserted
        }
    }
}

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

private extension Optional where Wrapped == Error {
    var isConnectivityFailure: Bool {
        guard let self else {
            return true
        }

        if let apiError = self as? ActualAPIError {
            switch apiError {
            case .invalidURL, .transport:
                return true
            case .invalidResponse, .missingTransactionID, .httpStatus, .decoding:
                return false
            }
        }

        return false
    }
}

enum ServerURLNormalizer {
    static func normalize(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme) else {
            return withScheme
        }

        if components.path.isEmpty || components.path == "/" {
            components.path = "/v1"
        }

        return components.string ?? withScheme
    }
}
