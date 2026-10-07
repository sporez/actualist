import Foundation

enum AppSwitcherPrivacyMode: String, Codable, CaseIterable, Identifiable {
    case off
    case whenBackgrounded
    case always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .whenBackgrounded: "When Backgrounded"
        case .always: "Always"
        }
    }

    var detail: String {
        switch self {
        case .off:
            "Never hide app contents in the app switcher."
        case .whenBackgrounded:
            "Hide contents after Actualist moves to the background without covering Control Center or system prompts."
        case .always:
            "Hide contents whenever Actualist becomes inactive, including for Control Center and most system prompts."
        }
    }
}

struct AppSettings: Codable, Equatable {
    var localFirstServerURLString: String = ""
    var fallbackServerURLString: String = ""
    var selectedBudgetID: String?
    var selectedBudgetName: String?
    var selectedLocalFirstFileID: String?
    var selectedLocalFirstGroupID: String?
    var theme: ActualistThemeOption = .actualPurple
    var displayDensity: ActualistDisplayDensity = .compact
    var monthDisplayPreference: MonthDisplayPreference = .automatic
    var greenIncomeTransactionAmountsEnabled: Bool = false
    var includeCarryoverCategoriesInOverspentAlerts: Bool = false
    var showTotalAssigned: Bool = false
    var monthSwipingEnabled: Bool = false
    var hideCarryoverArrows: Bool = false
    var showHiddenCategories: Bool = false
    var randomizedDisplayValuesEnabled: Bool = false
    var shortcutsEnabled: Bool = true
    var appSwitcherPrivacyMode: AppSwitcherPrivacyMode = .whenBackgrounded
    var developerModeUnlocked: Bool = false
    var accountOrderByBudgetID: [String: [String]] = [:]
    var defaultAccountIDByBudgetID: [String: String] = [:]
    var categoryGroupExpansionByBudgetID: [String: BudgetGroupExpansion] = [:]
    var reportCardOrder: [ReportCardKind] = ReportCardOrderPreference.defaultOrder
    var backgroundTransactionRefreshEnabled: Bool = false
    /// Optional SimpleFIN background bank sync. Default off; the toggle is
    /// consent to auto-apply server SimpleFIN downloads after a background
    /// `/sync/sync`. Never reads the device key; demo mode never runs it. New
    /// Transaction Alerts do not depend on this flag.
    var simplefinBackgroundSyncEnabled: Bool = false
    var backgroundRefreshDebug = BackgroundRefreshDebugInfo()
    var localFirstSyncDebug = LocalFirstSyncDebugInfo()
    var pendingNewTransactionIDsByAccount: [String: [String]] = [:]

    init(
        localFirstServerURLString: String = "",
        fallbackServerURLString: String = "",
        selectedBudgetID: String? = nil,
        selectedBudgetName: String? = nil,
        selectedLocalFirstFileID: String? = nil,
        selectedLocalFirstGroupID: String? = nil,
        theme: ActualistThemeOption = .actualPurple,
        displayDensity: ActualistDisplayDensity = .compact,
        monthDisplayPreference: MonthDisplayPreference = .automatic,
        greenIncomeTransactionAmountsEnabled: Bool = false,
        includeCarryoverCategoriesInOverspentAlerts: Bool = false,
        showTotalAssigned: Bool = false,
        monthSwipingEnabled: Bool = false,
        hideCarryoverArrows: Bool = false,
        showHiddenCategories: Bool = false,
        randomizedDisplayValuesEnabled: Bool = false,
        shortcutsEnabled: Bool = true,
        appSwitcherPrivacyMode: AppSwitcherPrivacyMode = .whenBackgrounded,
        developerModeUnlocked: Bool = false,
        accountOrderByBudgetID: [String: [String]] = [:],
        defaultAccountIDByBudgetID: [String: String] = [:],
        categoryGroupExpansionByBudgetID: [String: BudgetGroupExpansion] = [:],
        reportCardOrder: [ReportCardKind] = ReportCardOrderPreference.defaultOrder,
        backgroundTransactionRefreshEnabled: Bool = false,
        simplefinBackgroundSyncEnabled: Bool = false,
        backgroundRefreshDebug: BackgroundRefreshDebugInfo = BackgroundRefreshDebugInfo(),
        localFirstSyncDebug: LocalFirstSyncDebugInfo = LocalFirstSyncDebugInfo(),
        pendingNewTransactionIDsByAccount: [String: [String]] = [:]
    ) {
        self.localFirstServerURLString = localFirstServerURLString
        self.fallbackServerURLString = fallbackServerURLString
        self.selectedBudgetID = selectedBudgetID
        self.selectedBudgetName = selectedBudgetName
        self.selectedLocalFirstFileID = selectedLocalFirstFileID
        self.selectedLocalFirstGroupID = selectedLocalFirstGroupID
        self.theme = theme
        self.displayDensity = displayDensity
        self.monthDisplayPreference = monthDisplayPreference
        self.greenIncomeTransactionAmountsEnabled = greenIncomeTransactionAmountsEnabled
        self.includeCarryoverCategoriesInOverspentAlerts = includeCarryoverCategoriesInOverspentAlerts
        self.showTotalAssigned = showTotalAssigned
        self.monthSwipingEnabled = monthSwipingEnabled
        self.hideCarryoverArrows = hideCarryoverArrows
        self.showHiddenCategories = showHiddenCategories
        self.randomizedDisplayValuesEnabled = randomizedDisplayValuesEnabled
        self.shortcutsEnabled = shortcutsEnabled
        self.appSwitcherPrivacyMode = appSwitcherPrivacyMode
        self.developerModeUnlocked = developerModeUnlocked
        self.accountOrderByBudgetID = accountOrderByBudgetID
        self.defaultAccountIDByBudgetID = defaultAccountIDByBudgetID
        self.categoryGroupExpansionByBudgetID = categoryGroupExpansionByBudgetID
        self.reportCardOrder = ReportCardOrderPreference.normalized(reportCardOrder)
        self.backgroundTransactionRefreshEnabled = backgroundTransactionRefreshEnabled
        self.simplefinBackgroundSyncEnabled = simplefinBackgroundSyncEnabled
        self.backgroundRefreshDebug = backgroundRefreshDebug
        self.localFirstSyncDebug = localFirstSyncDebug
        self.pendingNewTransactionIDsByAccount = pendingNewTransactionIDsByAccount
    }

    /// A mistyped or unknown value in one field falls back to that field's
    /// default instead of discarding the whole settings blob.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localFirstServerURLString = container.lenient(String.self, forKey: .localFirstServerURLString) ?? ""
        fallbackServerURLString = container.lenient(String.self, forKey: .fallbackServerURLString) ?? ""
        selectedBudgetID = container.lenient(String.self, forKey: .selectedBudgetID)
        selectedBudgetName = container.lenient(String.self, forKey: .selectedBudgetName)
        selectedLocalFirstFileID = container.lenient(String.self, forKey: .selectedLocalFirstFileID)
        selectedLocalFirstGroupID = container.lenient(String.self, forKey: .selectedLocalFirstGroupID)
        theme = container.lenient(ActualistThemeOption.self, forKey: .theme) ?? .actualPurple
        displayDensity = container.lenient(ActualistDisplayDensity.self, forKey: .displayDensity) ?? .compact
        monthDisplayPreference = container.lenient(MonthDisplayPreference.self, forKey: .monthDisplayPreference) ?? .automatic
        greenIncomeTransactionAmountsEnabled = container.lenient(
            Bool.self,
            forKey: .greenIncomeTransactionAmountsEnabled
        ) ?? false
        includeCarryoverCategoriesInOverspentAlerts = container.lenient(
            Bool.self,
            forKey: .includeCarryoverCategoriesInOverspentAlerts
        ) ?? false
        showTotalAssigned = container.lenient(
            Bool.self,
            forKey: .showTotalAssigned
        ) ?? false
        monthSwipingEnabled = container.lenient(Bool.self, forKey: .monthSwipingEnabled) ?? false
        hideCarryoverArrows = container.lenient(
            Bool.self,
            forKey: .hideCarryoverArrows
        ) ?? false
        showHiddenCategories = container.lenient(
            Bool.self,
            forKey: .showHiddenCategories
        ) ?? false
        randomizedDisplayValuesEnabled = container.lenient(
            Bool.self,
            forKey: .randomizedDisplayValuesEnabled
        ) ?? false
        shortcutsEnabled = container.lenient(
            Bool.self,
            forKey: .shortcutsEnabled
        ) ?? true
        appSwitcherPrivacyMode = container.lenient(
            AppSwitcherPrivacyMode.self,
            forKey: .appSwitcherPrivacyMode
        ) ?? .whenBackgrounded
        developerModeUnlocked = container.lenient(
            Bool.self,
            forKey: .developerModeUnlocked
        ) ?? false
        accountOrderByBudgetID = container.lenient(
            [String: [String]].self,
            forKey: .accountOrderByBudgetID
        ) ?? [:]
        defaultAccountIDByBudgetID = container.lenient(
            [String: String].self,
            forKey: .defaultAccountIDByBudgetID
        ) ?? [:]
        categoryGroupExpansionByBudgetID = container.lenient(
            [String: BudgetGroupExpansion].self,
            forKey: .categoryGroupExpansionByBudgetID
        ) ?? [:]
        let persistedReportCardOrder = container.lenient(
            [String].self,
            forKey: .reportCardOrder
        ) ?? []
        reportCardOrder = ReportCardOrderPreference.normalized(
            persistedReportCardOrder.compactMap(ReportCardKind.init(rawValue:))
        )
        backgroundTransactionRefreshEnabled = container.lenient(
            Bool.self,
            forKey: .backgroundTransactionRefreshEnabled
        ) ?? false
        simplefinBackgroundSyncEnabled = container.lenient(
            Bool.self,
            forKey: .simplefinBackgroundSyncEnabled
        ) ?? false
        backgroundRefreshDebug = container.lenient(
            BackgroundRefreshDebugInfo.self,
            forKey: .backgroundRefreshDebug
        ) ?? BackgroundRefreshDebugInfo()
        localFirstSyncDebug = container.lenient(
            LocalFirstSyncDebugInfo.self,
            forKey: .localFirstSyncDebug
        ) ?? LocalFirstSyncDebugInfo()
        pendingNewTransactionIDsByAccount = container.lenient(
            [String: [String]].self,
            forKey: .pendingNewTransactionIDsByAccount
        ) ?? [:]
    }

    /// BGAppRefresh stays registered for alerts or background bank auto-apply.
    /// Alerts do not depend on Bank Sync.
    var wantsBackgroundAppRefresh: Bool {
        backgroundTransactionRefreshEnabled || simplefinBackgroundSyncEnabled
    }
}

struct BackgroundRefreshDebugInfo: Codable, Equatable {
    var totalWakeCount: Int = 0
    var recentRuns: [BackgroundRefreshDebugRun] = []
    var totalScheduleAttemptCount: Int = 0
    var recentScheduleAttempts: [BackgroundRefreshScheduleAttempt] = []
    var recentPendingIDClears: [BackgroundPendingIDClearEvent] = []

    var wakeCount: Int {
        totalWakeCount
    }

    var scheduleAttemptCount: Int {
        totalScheduleAttemptCount
    }

    private enum CodingKeys: String, CodingKey {
        case totalWakeCount, recentRuns, totalScheduleAttemptCount, recentScheduleAttempts
        case recentPendingIDClears
    }

    init(
        totalWakeCount: Int = 0,
        recentRuns: [BackgroundRefreshDebugRun] = [],
        totalScheduleAttemptCount: Int = 0,
        recentScheduleAttempts: [BackgroundRefreshScheduleAttempt] = [],
        recentPendingIDClears: [BackgroundPendingIDClearEvent] = []
    ) {
        self.totalWakeCount = totalWakeCount
        self.recentRuns = recentRuns
        self.totalScheduleAttemptCount = totalScheduleAttemptCount
        self.recentScheduleAttempts = recentScheduleAttempts
        self.recentPendingIDClears = recentPendingIDClears
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalWakeCount = try container.decodeIfPresent(Int.self, forKey: .totalWakeCount) ?? 0
        recentRuns = try container.decodeIfPresent([BackgroundRefreshDebugRun].self, forKey: .recentRuns) ?? []
        totalScheduleAttemptCount = try container.decodeIfPresent(Int.self, forKey: .totalScheduleAttemptCount) ?? 0
        recentScheduleAttempts = try container.decodeIfPresent(
            [BackgroundRefreshScheduleAttempt].self,
            forKey: .recentScheduleAttempts
        ) ?? []
        recentPendingIDClears = try container.decodeIfPresent(
            [BackgroundPendingIDClearEvent].self,
            forKey: .recentPendingIDClears
        ) ?? []
    }
}

struct BackgroundPendingIDClearEvent: Codable, Equatable, Identifiable {
    enum Scope: String, Codable, Equatable, Sendable {
        case account
        case budget
    }

    let id: UUID
    let date: Date
    let scope: Scope
    let clearedCount: Int
}

struct BackgroundRefreshDebugRun: Codable, Equatable, Identifiable {
    let id: UUID
    var wakeDate: Date
    var completionDate: Date?
    var succeeded: Bool?
    var message: String
    var diagnosticDetails: BackgroundRefreshDiagnosticDetails? = nil
}

struct BackgroundRefreshScheduleAttempt: Codable, Equatable, Identifiable {
    let id: UUID
    var date: Date
    var earliestBeginDate: Date?
    var succeeded: Bool
    var message: String
}

struct LocalFirstSyncDebugInfo: Codable, Equatable {
    var totalEventCount: Int = 0
    var recentEvents: [LocalFirstSyncDebugEvent] = []
}

struct LocalFirstSyncDebugEvent: Codable, Equatable, Identifiable, Sendable {
    enum Outcome: String, Codable, Equatable, Sendable {
        case queued
        case succeeded
        case failed
    }

    /// Which server endpoint a sync attempt used. `nil` for events that are
    /// not a server round-trip (e.g. a local queue event).
    enum Endpoint: String, Codable, Equatable, Sendable {
        case primary
        case fallback
    }

    let id: UUID
    let date: Date
    let outcome: Outcome
    let pendingBefore: Int
    let uploadedCount: Int
    let downloadedCount: Int
    let pendingAfter: Int
    let message: String
    let endpoint: Endpoint?

    var diagnosticMessage: String {
        SafeSyncDiagnostic.eventMessage(message, outcome: outcome)
    }

    init(
        id: UUID,
        date: Date,
        outcome: Outcome,
        pendingBefore: Int,
        uploadedCount: Int,
        downloadedCount: Int,
        pendingAfter: Int,
        message: String,
        endpoint: Endpoint? = nil
    ) {
        self.id = id
        self.date = date
        self.outcome = outcome
        self.pendingBefore = pendingBefore
        self.uploadedCount = uploadedCount
        self.downloadedCount = downloadedCount
        self.pendingAfter = pendingAfter
        self.message = message
        self.endpoint = endpoint
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, outcome, pendingBefore, uploadedCount, downloadedCount
        case pendingAfter, message, endpoint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        outcome = try container.decode(Outcome.self, forKey: .outcome)
        pendingBefore = try container.decode(Int.self, forKey: .pendingBefore)
        uploadedCount = try container.decode(Int.self, forKey: .uploadedCount)
        downloadedCount = try container.decode(Int.self, forKey: .downloadedCount)
        pendingAfter = try container.decode(Int.self, forKey: .pendingAfter)
        // Older releases persisted free-form server responses. Decode the
        // metadata, but never expose their untrusted message again.
        let storedMessage = try container.decode(String.self, forKey: .message)
        message = SafeSyncDiagnostic.eventMessage(storedMessage, outcome: outcome)
        endpoint = try container.decodeIfPresent(Endpoint.self, forKey: .endpoint)
    }
}

private extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

struct AppSettingsStore {
    @MainActor
    static let live = AppSettingsStore(defaults: .standard)

    let defaults: UserDefaults
    private let key = "actualist.settings.v1"

    /// Holds the first blob that could not be read as a settings object so a
    /// later save cannot destroy the only copy.
    static let corruptBackupKey = "actualist.settings.v1.corrupt-backup"

    /// Sync debug history lives under its own key so recording an event does
    /// not re-encode and save every other setting.
    static let syncDebugHistoryKey = "actualist.syncDebugHistory.v1"

    func load() -> AppSettings {
        var settings = AppSettings()
        if let data = defaults.data(forKey: key) {
            guard let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
                if defaults.data(forKey: Self.corruptBackupKey) == nil {
                    defaults.set(data, forKey: Self.corruptBackupKey)
                }
                return AppSettings()
            }
            settings = decoded
        }

        if let history = loadSyncDebugHistory() {
            settings.localFirstSyncDebug = history
        } else if settings.localFirstSyncDebug != LocalFirstSyncDebugInfo() {
            // One-time migration: history used to live inside the settings blob.
            saveSyncDebugHistory(settings.localFirstSyncDebug)
        }
        return settings
    }

    func loadSyncDebugHistory() -> LocalFirstSyncDebugInfo? {
        defaults.data(forKey: Self.syncDebugHistoryKey)
            .flatMap { try? JSONDecoder().decode(LocalFirstSyncDebugInfo.self, from: $0) }
    }

    func saveSyncDebugHistory(_ history: LocalFirstSyncDebugInfo) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Self.syncDebugHistoryKey)
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }

        defaults.set(data, forKey: key)
    }
}
