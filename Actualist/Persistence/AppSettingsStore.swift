import Foundation

struct AppSettings: Codable, Equatable {
    var serverURLString: String = ""
    var selectedBudgetID: String?
    var selectedBudgetName: String?
    var theme: ActualistThemeOption = .actualPurple
    var displayDensity: ActualistDisplayDensity = .compact

    init(
        serverURLString: String = "",
        selectedBudgetID: String? = nil,
        selectedBudgetName: String? = nil,
        theme: ActualistThemeOption = .actualPurple,
        displayDensity: ActualistDisplayDensity = .compact
    ) {
        self.serverURLString = serverURLString
        self.selectedBudgetID = selectedBudgetID
        self.selectedBudgetName = selectedBudgetName
        self.theme = theme
        self.displayDensity = displayDensity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverURLString = try container.decodeIfPresent(String.self, forKey: .serverURLString) ?? ""
        selectedBudgetID = try container.decodeIfPresent(String.self, forKey: .selectedBudgetID)
        selectedBudgetName = try container.decodeIfPresent(String.self, forKey: .selectedBudgetName)
        theme = try container.decodeIfPresent(ActualistThemeOption.self, forKey: .theme) ?? .actualPurple
        displayDensity = try container.decodeIfPresent(ActualistDisplayDensity.self, forKey: .displayDensity) ?? .compact
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
