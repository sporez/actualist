import Foundation

enum BackendMode: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case restAPI
    case localFirstSync

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restAPI:
            "HTTP API"
        case .localFirstSync:
            "Local First"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var backendMode: BackendMode = .restAPI
    var serverURLString: String = ""
    var localFirstServerURLString: String = ""
    var selectedBudgetID: String?
    var selectedBudgetName: String?
    var selectedLocalFirstFileID: String?
    var selectedLocalFirstGroupID: String?
    var theme: ActualistThemeOption = .actualPurple
    var displayDensity: ActualistDisplayDensity = .compact
    var randomizedDisplayValuesEnabled: Bool = false
    var developerModeUnlocked: Bool = false
    var accountOrderByBudgetID: [String: [String]] = [:]
    var backgroundTransactionRefreshEnabled: Bool = false
    var backgroundRefreshDebug = BackgroundRefreshDebugInfo()
    var pendingNewTransactionIDsByAccount: [String: [String]] = [:]

    init(
        serverURLString: String = "",
        backendMode: BackendMode = .restAPI,
        localFirstServerURLString: String = "",
        selectedBudgetID: String? = nil,
        selectedBudgetName: String? = nil,
        selectedLocalFirstFileID: String? = nil,
        selectedLocalFirstGroupID: String? = nil,
        theme: ActualistThemeOption = .actualPurple,
        displayDensity: ActualistDisplayDensity = .compact,
        randomizedDisplayValuesEnabled: Bool = false,
        developerModeUnlocked: Bool = false,
        accountOrderByBudgetID: [String: [String]] = [:],
        backgroundTransactionRefreshEnabled: Bool = false,
        backgroundRefreshDebug: BackgroundRefreshDebugInfo = BackgroundRefreshDebugInfo(),
        pendingNewTransactionIDsByAccount: [String: [String]] = [:]
    ) {
        self.backendMode = backendMode
        self.serverURLString = serverURLString
        self.localFirstServerURLString = localFirstServerURLString
        self.selectedBudgetID = selectedBudgetID
        self.selectedBudgetName = selectedBudgetName
        self.selectedLocalFirstFileID = selectedLocalFirstFileID
        self.selectedLocalFirstGroupID = selectedLocalFirstGroupID
        self.theme = theme
        self.displayDensity = displayDensity
        self.randomizedDisplayValuesEnabled = randomizedDisplayValuesEnabled
        self.developerModeUnlocked = developerModeUnlocked
        self.accountOrderByBudgetID = accountOrderByBudgetID
        self.backgroundTransactionRefreshEnabled = backgroundTransactionRefreshEnabled
        self.backgroundRefreshDebug = backgroundRefreshDebug
        self.pendingNewTransactionIDsByAccount = pendingNewTransactionIDsByAccount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backendMode = try container.decodeIfPresent(BackendMode.self, forKey: .backendMode) ?? .restAPI
        serverURLString = try container.decodeIfPresent(String.self, forKey: .serverURLString) ?? ""
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
        developerModeUnlocked = try container.decodeIfPresent(
            Bool.self,
            forKey: .developerModeUnlocked
        ) ?? false
        accountOrderByBudgetID = try container.decodeIfPresent(
            [String: [String]].self,
            forKey: .accountOrderByBudgetID
        ) ?? [:]
        backgroundTransactionRefreshEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .backgroundTransactionRefreshEnabled
        ) ?? false
        backgroundRefreshDebug = try container.decodeIfPresent(
            BackgroundRefreshDebugInfo.self,
            forKey: .backgroundRefreshDebug
        ) ?? BackgroundRefreshDebugInfo()
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
