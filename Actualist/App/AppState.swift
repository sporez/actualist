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
    private let snapshotStore: OfflineSnapshotStore
    private var activeNetworkRequestCount = 0
    private var developerUnlockTapCount = 0
    private var developerUnlockLastTapDate: Date?
    private let developerUnlockRequiredTapCount = 10
    private let developerUnlockVisibleCountdownThreshold = 5
    private let developerUnlockResetInterval: TimeInterval = 20

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

    func updateRandomizedDisplayValuesEnabled(_ isEnabled: Bool) {
        settings.randomizedDisplayValuesEnabled = isEnabled
        settingsStore.save(settings)
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

        do {
            try await dataStore.refreshAccounts(budgetID: budgetID)
            let accounts = dataStore.accountsByBudget[budgetID]?.value ?? []
            let linkedAccounts = accounts.filter { $0.bankSyncLinked && !$0.closed }
            var newTransactionCount = 0
            var succeededAccountCount = 0
            var failedAccountMessages: [String] = []

            for account in linkedAccounts {
                do {
                    let result = try await dataStore.syncBankAccountAndFindNewTransactions(
                        budgetID: budgetID,
                        account: account
                    )
                    succeededAccountCount += 1
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
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        throw error
                    }
                    failedAccountMessages.append(backgroundRefreshFailureMessage(for: account, error: error))
                }
            }

            persistCurrentSnapshot()
            let hasAccountFailures = !failedAccountMessages.isEmpty
            recordBackgroundRefreshCompletion(
                runID: debugRunID,
                success: !hasAccountFailures,
                message: backgroundRefreshCompletionMessage(
                    checkedAccountCount: linkedAccounts.count,
                    succeededAccountCount: succeededAccountCount,
                    failedAccountMessages: failedAccountMessages,
                    newTransactionCount: newTransactionCount
                )
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

    private func backgroundRefreshCompletionMessage(
        checkedAccountCount: Int,
        succeededAccountCount: Int,
        failedAccountMessages: [String],
        newTransactionCount: Int
    ) -> String {
        guard !failedAccountMessages.isEmpty else {
            return "Checked \(checkedAccountCount) linked accounts; found \(newTransactionCount) new transactions"
        }

        let failedSummary = failedAccountMessages.joined(separator: "; ")
        return "Checked \(checkedAccountCount) linked accounts; \(succeededAccountCount) succeeded; \(failedAccountMessages.count) failed: \(failedSummary); found \(newTransactionCount) new transactions"
    }

    private func backgroundRefreshFailureMessage(for account: ActualAccount, error: Error) -> String {
        "\(account.name): \(Self.condensedBackgroundRefreshError(error))"
    }

    private static func condensedBackgroundRefreshError(_ error: Error) -> String {
        let message: String
        if let apiError = error as? ActualAPIError {
            switch apiError {
            case .httpStatus(let status, let serverMessage):
                if let serverMessage, !serverMessage.isEmpty {
                    message = "HTTP \(status): \(serverMessage)"
                } else {
                    message = "HTTP \(status)"
                }
            case .transport(let urlError):
                message = urlError?.localizedDescription ?? "network error"
            default:
                message = apiError.localizedDescription
            }
        } else {
            message = error.localizedDescription
        }

        let oneLineMessage = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if oneLineMessage.count <= 90 {
            return oneLineMessage
        }
        return "\(oneLineMessage.prefix(87))..."
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
        if settings.serverURLString.isEmpty {
            reasons.append("server URL missing")
        }
        if apiKey.isEmpty {
            reasons.append("API key unavailable")
        }
        if makeClient() == nil {
            reasons.append("API client unavailable")
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

    #if DEBUG
    func postDebugNewTransactionNotification() async throws -> String {
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

        if dataStore.accountsByBudget[budgetID]?.value == nil {
            try await dataStore.refreshAccountsWithBalances(budgetID: budgetID)
        }

        let accounts = dataStore.accountDisplays(budgetID: budgetID).map(\.account)
        guard let account = accounts.first(where: { account in
            account.bankSyncLinked
                && !account.closed
                && account.name.localizedCaseInsensitiveContains("amex")
        }) ?? accounts.first(where: { $0.bankSyncLinked && !$0.closed })
            ?? accounts.first(where: { !$0.closed })
            ?? accounts.first else {
            throw DebugNotificationError.noAccounts
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        try await postNewTransactionsNotification(
            account: account,
            budgetID: budgetID,
            count: 1,
            trigger: trigger
        )
        return account.name
    }
    #endif

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
        count: Int,
        trigger: UNNotificationTrigger? = nil
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
            trigger: trigger
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
