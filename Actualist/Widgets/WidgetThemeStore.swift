import Foundation

struct WidgetThemeStore {
    let defaults: UserDefaults?

    static var live: WidgetThemeStore {
        WidgetThemeStore(defaults: UserDefaults(suiteName: WidgetAppGroup.identifier))
    }

    private let key = "widgetTheme"

    func load() -> ActualistThemeOption {
        defaults?.string(forKey: key).flatMap(ActualistThemeOption.init(rawValue:)) ?? .actualPurple
    }

    /// Compare the persisted value so a cold app launch also repairs stale widget appearance.
    func saveIfChanged(_ theme: ActualistThemeOption) -> Bool {
        guard let defaults, defaults.string(forKey: key) != theme.rawValue else { return false }
        defaults.set(theme.rawValue, forKey: key)
        return true
    }
}
