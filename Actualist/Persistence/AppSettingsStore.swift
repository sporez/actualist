import Foundation

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
    var selectedBudgetID: String?
    var selectedBudgetName: String?
    var selectedLocalFirstFileID: String?
    var selectedLocalFirstGroupID: String?
    var theme: ActualistThemeOption = .actualPurple
    var displayDensity: ActualistDisplayDensity = .compact
    var randomizedDisplayValuesEnabled: Bool = false
    var enabledExperimentalFeatures: Set<ExperimentalFeature> = []
    var developerModeUnlocked: Bool = false
    var accountOrderByBudgetID: [String: [String]] = [:]
    var reportCardOrder: [ReportCardKind] = ReportCardOrderPreference.defaultOrder
    var backgroundTransactionRefreshEnabled: Bool = false
    /// Single developer gate for every local-first write (transactions, budget assign/move,
    /// and — as they land — templates). Was three redundant flags all wired to this one value.
    var localFirstWritesEnabled: Bool = false
    var backgroundRefreshDebug = BackgroundRefreshDebugInfo()
    var localFirstSyncDebug = LocalFirstSyncDebugInfo()
    var pendingNewTransactionIDsByAccount: [String: [String]] = [:]

    init(
        localFirstServerURLString: String = "",
        selectedBudgetID: String? = nil,
        selectedBudgetName: String? = nil,
        selectedLocalFirstFileID: String? = nil,
        selectedLocalFirstGroupID: String? = nil,
        theme: ActualistThemeOption = .actualPurple,
        displayDensity: ActualistDisplayDensity = .compact,
        randomizedDisplayValuesEnabled: Bool = false,
        enabledExperimentalFeatures: Set<ExperimentalFeature> = [],
        developerModeUnlocked: Bool = false,
        accountOrderByBudgetID: [String: [String]] = [:],
        reportCardOrder: [ReportCardKind] = ReportCardOrderPreference.defaultOrder,
        backgroundTransactionRefreshEnabled: Bool = false,
        localFirstWritesEnabled: Bool = false,
        backgroundRefreshDebug: BackgroundRefreshDebugInfo = BackgroundRefreshDebugInfo(),
        localFirstSyncDebug: LocalFirstSyncDebugInfo = LocalFirstSyncDebugInfo(),
        pendingNewTransactionIDsByAccount: [String: [String]] = [:]
    ) {
        self.localFirstServerURLString = localFirstServerURLString
        self.selectedBudgetID = selectedBudgetID
        self.selectedBudgetName = selectedBudgetName
        self.selectedLocalFirstFileID = selectedLocalFirstFileID
        self.selectedLocalFirstGroupID = selectedLocalFirstGroupID
        self.theme = theme
        self.displayDensity = displayDensity
        self.randomizedDisplayValuesEnabled = randomizedDisplayValuesEnabled
        self.enabledExperimentalFeatures = enabledExperimentalFeatures
        self.developerModeUnlocked = developerModeUnlocked
        self.accountOrderByBudgetID = accountOrderByBudgetID
        self.reportCardOrder = ReportCardOrderPreference.normalized(reportCardOrder)
        self.backgroundTransactionRefreshEnabled = backgroundTransactionRefreshEnabled
        self.localFirstWritesEnabled = localFirstWritesEnabled
        self.backgroundRefreshDebug = backgroundRefreshDebug
        self.localFirstSyncDebug = localFirstSyncDebug
        self.pendingNewTransactionIDsByAccount = pendingNewTransactionIDsByAccount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localFirstServerURLString = try container.decodeIfPresent(String.self, forKey: .localFirstServerURLString) ?? ""
        selectedBudgetID = try container.decodeIfPresent(String.self, forKey: .selectedBudgetID)
        selectedBudgetName = try container.decodeIfPresent(String.self, forKey: .selectedBudgetName)
        selectedLocalFirstFileID = try container.decodeIfPresent(String.self, forKey: .selectedLocalFirstFileID)
        selectedLocalFirstGroupID = try container.decodeIfPresent(String.self, forKey: .selectedLocalFirstGroupID)
        theme = try container.decodeIfPresent(ActualistThemeOption.self, forKey: .theme) ?? .actualPurple
        displayDensity = try container.decodeIfPresent(ActualistDisplayDensity.self, forKey: .displayDensity) ?? .compact
        randomizedDisplayValuesEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .randomizedDisplayValuesEnabled
        ) ?? false
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
        if let writesEnabled = try container.decodeIfPresent(Bool.self, forKey: .localFirstWritesEnabled) {
            localFirstWritesEnabled = writesEnabled
        } else {
            // Fall back to the retired per-feature flag name so existing dev state persists.
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            localFirstWritesEnabled = try legacy.decodeIfPresent(
                Bool.self,
                forKey: .localFirstTransactionCreationEnabled
            ) ?? false
        }
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

    private enum LegacyCodingKeys: String, CodingKey {
        case localFirstTransactionCreationEnabled
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

    let id: UUID
    let date: Date
    let outcome: Outcome
    let pendingBefore: Int
    let uploadedCount: Int
    let downloadedCount: Int
    let pendingAfter: Int
    let message: String
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
