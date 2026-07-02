import Foundation

struct AppSettings: Codable, Equatable {
    var serverURLString: String = ""
    var selectedBudgetID: String?
    var selectedBudgetName: String?
    var theme: ActualistThemeOption = .actualPurple
    var displayDensity: ActualistDisplayDensity = .compact
    var accountOrderByBudgetID: [String: [String]] = [:]
    var backgroundTransactionRefreshEnabled: Bool = false
    var backgroundRefreshDebug = BackgroundRefreshDebugInfo()
    var pendingNewTransactionIDsByAccount: [String: [String]] = [:]

    init(
        serverURLString: String = "",
        selectedBudgetID: String? = nil,
        selectedBudgetName: String? = nil,
        theme: ActualistThemeOption = .actualPurple,
        displayDensity: ActualistDisplayDensity = .compact,
        accountOrderByBudgetID: [String: [String]] = [:],
        backgroundTransactionRefreshEnabled: Bool = false,
        backgroundRefreshDebug: BackgroundRefreshDebugInfo = BackgroundRefreshDebugInfo(),
        pendingNewTransactionIDsByAccount: [String: [String]] = [:]
    ) {
        self.serverURLString = serverURLString
        self.selectedBudgetID = selectedBudgetID
        self.selectedBudgetName = selectedBudgetName
        self.theme = theme
        self.displayDensity = displayDensity
        self.accountOrderByBudgetID = accountOrderByBudgetID
        self.backgroundTransactionRefreshEnabled = backgroundTransactionRefreshEnabled
        self.backgroundRefreshDebug = backgroundRefreshDebug
        self.pendingNewTransactionIDsByAccount = pendingNewTransactionIDsByAccount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverURLString = try container.decodeIfPresent(String.self, forKey: .serverURLString) ?? ""
        selectedBudgetID = try container.decodeIfPresent(String.self, forKey: .selectedBudgetID)
        selectedBudgetName = try container.decodeIfPresent(String.self, forKey: .selectedBudgetName)
        theme = try container.decodeIfPresent(ActualistThemeOption.self, forKey: .theme) ?? .actualPurple
        displayDensity = try container.decodeIfPresent(ActualistDisplayDensity.self, forKey: .displayDensity) ?? .compact
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
