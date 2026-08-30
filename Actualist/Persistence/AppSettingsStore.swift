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

enum ExperimentalFeature: String, Codable, CaseIterable, Identifiable {
    case budgetTemplates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .budgetTemplates: "Budget Templates"
        }
    }

    var detail: String {
        switch self {
        case .budgetTemplates: "Shows template actions on the Budget screen."
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
    var greenIncomeTransactionAmountsEnabled: Bool = false
    var includeCarryoverCategoriesInOverspentAlerts: Bool = false
    var showTotalAssigned: Bool = false
    var showHiddenCategories: Bool = false
    var randomizedDisplayValuesEnabled: Bool = false
    var shortcutsEnabled: Bool = true
    var appSwitcherPrivacyMode: AppSwitcherPrivacyMode = .whenBackgrounded
    var enabledExperimentalFeatures: Set<ExperimentalFeature> = []
    var developerModeUnlocked: Bool = false
    var accountOrderByBudgetID: [String: [String]] = [:]
    var defaultAccountIDByBudgetID: [String: String] = [:]
    var reportCardOrder: [ReportCardKind] = ReportCardOrderPreference.defaultOrder
    var backgroundTransactionRefreshEnabled: Bool = false
    /// Optional SimpleFIN background bank sync (bank-sync plan Phase 6).
    /// Default off; the toggle is consent to auto-apply server SimpleFIN
    /// downloads after a background `/sync/sync`. Never reads the Phase 5
    /// device key; demo mode never runs it.
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
        greenIncomeTransactionAmountsEnabled: Bool = false,
        includeCarryoverCategoriesInOverspentAlerts: Bool = false,
        showTotalAssigned: Bool = false,
        showHiddenCategories: Bool = false,
        randomizedDisplayValuesEnabled: Bool = false,
        shortcutsEnabled: Bool = true,
        appSwitcherPrivacyMode: AppSwitcherPrivacyMode = .whenBackgrounded,
        enabledExperimentalFeatures: Set<ExperimentalFeature> = [],
        developerModeUnlocked: Bool = false,
        accountOrderByBudgetID: [String: [String]] = [:],
        defaultAccountIDByBudgetID: [String: String] = [:],
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
        self.greenIncomeTransactionAmountsEnabled = greenIncomeTransactionAmountsEnabled
        self.includeCarryoverCategoriesInOverspentAlerts = includeCarryoverCategoriesInOverspentAlerts
        self.showTotalAssigned = showTotalAssigned
        self.showHiddenCategories = showHiddenCategories
        self.randomizedDisplayValuesEnabled = randomizedDisplayValuesEnabled
        self.shortcutsEnabled = shortcutsEnabled
        self.appSwitcherPrivacyMode = appSwitcherPrivacyMode
        self.enabledExperimentalFeatures = enabledExperimentalFeatures
        self.developerModeUnlocked = developerModeUnlocked
        self.accountOrderByBudgetID = accountOrderByBudgetID
        self.defaultAccountIDByBudgetID = defaultAccountIDByBudgetID
        self.reportCardOrder = ReportCardOrderPreference.normalized(reportCardOrder)
        self.backgroundTransactionRefreshEnabled = backgroundTransactionRefreshEnabled
        self.simplefinBackgroundSyncEnabled = simplefinBackgroundSyncEnabled
        self.backgroundRefreshDebug = backgroundRefreshDebug
        self.localFirstSyncDebug = localFirstSyncDebug
        self.pendingNewTransactionIDsByAccount = pendingNewTransactionIDsByAccount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localFirstServerURLString = try container.decodeIfPresent(String.self, forKey: .localFirstServerURLString) ?? ""
        fallbackServerURLString = try container.decodeIfPresent(String.self, forKey: .fallbackServerURLString) ?? ""
        selectedBudgetID = try container.decodeIfPresent(String.self, forKey: .selectedBudgetID)
        selectedBudgetName = try container.decodeIfPresent(String.self, forKey: .selectedBudgetName)
        selectedLocalFirstFileID = try container.decodeIfPresent(String.self, forKey: .selectedLocalFirstFileID)
        selectedLocalFirstGroupID = try container.decodeIfPresent(String.self, forKey: .selectedLocalFirstGroupID)
        theme = try container.decodeIfPresent(ActualistThemeOption.self, forKey: .theme) ?? .actualPurple
        displayDensity = try container.decodeIfPresent(ActualistDisplayDensity.self, forKey: .displayDensity) ?? .compact
        greenIncomeTransactionAmountsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .greenIncomeTransactionAmountsEnabled
        ) ?? false
        includeCarryoverCategoriesInOverspentAlerts = try container.decodeIfPresent(
            Bool.self,
            forKey: .includeCarryoverCategoriesInOverspentAlerts
        ) ?? false
        showTotalAssigned = try container.decodeIfPresent(
            Bool.self,
            forKey: .showTotalAssigned
        ) ?? false
        showHiddenCategories = try container.decodeIfPresent(
            Bool.self,
            forKey: .showHiddenCategories
        ) ?? false
        randomizedDisplayValuesEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .randomizedDisplayValuesEnabled
        ) ?? false
        shortcutsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .shortcutsEnabled
        ) ?? true
        appSwitcherPrivacyMode = try container.decodeIfPresent(
            AppSwitcherPrivacyMode.self,
            forKey: .appSwitcherPrivacyMode
        ) ?? .whenBackgrounded
        let persistedExperimentalFeatures = try container.decodeIfPresent(
            [String].self,
            forKey: .enabledExperimentalFeatures
        ) ?? []
        enabledExperimentalFeatures = Set(
            persistedExperimentalFeatures.compactMap(ExperimentalFeature.init(rawValue:))
        )
        developerModeUnlocked = try container.decodeIfPresent(
            Bool.self,
            forKey: .developerModeUnlocked
        ) ?? false
        accountOrderByBudgetID = try container.decodeIfPresent(
            [String: [String]].self,
            forKey: .accountOrderByBudgetID
        ) ?? [:]
        defaultAccountIDByBudgetID = try container.decodeIfPresent(
            [String: String].self,
            forKey: .defaultAccountIDByBudgetID
        ) ?? [:]
        let persistedReportCardOrder = try container.decodeIfPresent(
            [String].self,
            forKey: .reportCardOrder
        ) ?? []
        reportCardOrder = ReportCardOrderPreference.normalized(
            persistedReportCardOrder.compactMap(ReportCardKind.init(rawValue:))
        )
        backgroundTransactionRefreshEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .backgroundTransactionRefreshEnabled
        ) ?? false
        simplefinBackgroundSyncEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .simplefinBackgroundSyncEnabled
        ) ?? false
        backgroundRefreshDebug = try container.decodeIfPresent(
            BackgroundRefreshDebugInfo.self,
            forKey: .backgroundRefreshDebug
        ) ?? BackgroundRefreshDebugInfo()
        localFirstSyncDebug = try container.decodeIfPresent(
            LocalFirstSyncDebugInfo.self,
            forKey: .localFirstSyncDebug
        ) ?? LocalFirstSyncDebugInfo()
        pendingNewTransactionIDsByAccount = try container.decodeIfPresent(
            [String: [String]].self,
            forKey: .pendingNewTransactionIDsByAccount
        ) ?? [:]
    }
}

struct BackgroundRefreshDebugInfo: Codable, Equatable {
    var totalWakeCount: Int = 0
    var recentRuns: [BackgroundRefreshDebugRun] = []
    var totalScheduleAttemptCount: Int = 0
    var recentScheduleAttempts: [BackgroundRefreshScheduleAttempt] = []

    var wakeCount: Int {
        totalWakeCount
    }

    var scheduleAttemptCount: Int {
        totalScheduleAttemptCount
    }
}

struct BackgroundRefreshDebugRun: Codable, Equatable, Identifiable {
    let id: UUID
    var wakeDate: Date
    var completionDate: Date?
    var succeeded: Bool?
    var message: String
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
        message = try container.decode(String.self, forKey: .message)
        endpoint = try container.decodeIfPresent(Endpoint.self, forKey: .endpoint)
    }
}

struct AppSettingsStore {
    static let live = AppSettingsStore(defaults: .standard)

    let defaults: UserDefaults
    private let key = "actualist.settings.v1"

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }

        return settings
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }

        defaults.set(data, forKey: key)
    }
}
