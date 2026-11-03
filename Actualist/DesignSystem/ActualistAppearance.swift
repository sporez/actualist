import SwiftUI

/// The Light Theme and Dark Theme used while Match System is on.
struct SystemThemePair: Codable, Equatable, Sendable {
    let light: ActualistThemeOption
    let dark: ActualistThemeOption

    /// A slot holding the other scheme's theme falls back to Actual Purple of
    /// the right scheme, so stored data can never show a dark theme in light mode.
    init(light: ActualistThemeOption, dark: ActualistThemeOption) {
        self.light = light.colorScheme == .light ? light : .actualPurpleLight
        self.dark = dark.colorScheme == .dark ? dark : .actualPurple
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            light: try container.decode(ActualistThemeOption.self, forKey: .light),
            dark: try container.decode(ActualistThemeOption.self, forKey: .dark)
        )
    }

    /// Puts `theme` in its own slot and Actual Purple of the other scheme in the other.
    static func seeded(from theme: ActualistThemeOption) -> SystemThemePair {
        theme.colorScheme == .light
            ? SystemThemePair(light: theme, dark: .actualPurple)
            : SystemThemePair(light: .actualPurpleLight, dark: theme)
    }

    func option(for colorScheme: ColorScheme) -> ActualistThemeOption {
        colorScheme == .light ? light : dark
    }
}

/// How the app picks its theme: one fixed theme, or a pair that follows the
/// phone's light/dark setting.
enum ActualistAppearance: Equatable, Sendable {
    case fixed(ActualistThemeOption)
    case matchingSystem(SystemThemePair)

    func option(for colorScheme: ColorScheme) -> ActualistThemeOption {
        switch self {
        case .fixed(let option): option
        case .matchingSystem(let pair): pair.option(for: colorScheme)
        }
    }

    /// `nil` lets the system choose, which is what makes the pair follow the phone.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .fixed(let option): option.colorScheme
        case .matchingSystem: nil
        }
    }
}
