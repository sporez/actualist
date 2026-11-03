import Foundation

/// The app publishes its appearance here so the widget extension never reads
/// the app's active-theme global.
struct WidgetThemeStore {
    let defaults: UserDefaults?

    static var live: WidgetThemeStore {
        WidgetThemeStore(defaults: UserDefaults(suiteName: WidgetAppGroup.identifier))
    }

    /// The fixed theme. A pair under `systemThemesKey` means Match System is on.
    private let key = "widgetTheme"
    private let systemThemesKey = "widgetSystemThemes"

    func load() -> ActualistAppearance {
        if let pair = storedPair() {
            return .matchingSystem(pair)
        }
        return .fixed(defaults?.string(forKey: key).flatMap(ActualistThemeOption.init(rawValue:)) ?? .actualPurple)
    }

    /// Compare the persisted value so a cold app launch also repairs stale widget appearance.
    func saveIfChanged(_ appearance: ActualistAppearance) -> Bool {
        guard let defaults else { return false }
        switch appearance {
        case .fixed(let theme):
            guard defaults.string(forKey: key) != theme.rawValue
                || defaults.object(forKey: systemThemesKey) != nil else { return false }
            defaults.set(theme.rawValue, forKey: key)
            defaults.removeObject(forKey: systemThemesKey)
        case .matchingSystem(let pair):
            guard storedPair() != pair, let data = try? JSONEncoder().encode(pair) else { return false }
            defaults.set(data, forKey: systemThemesKey)
        }
        return true
    }

    private func storedPair() -> SystemThemePair? {
        defaults?.data(forKey: systemThemesKey).flatMap { try? JSONDecoder().decode(SystemThemePair.self, from: $0) }
    }
}
