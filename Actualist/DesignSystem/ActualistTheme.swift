import SwiftUI

enum ActualistThemeOption: String, Codable, CaseIterable, Identifiable {
    case actualPurple
    case amethystHaze
    case emberAmber
    case blueCurrent
    case roseQuartz
    case whyNab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .actualPurple: "Actual Purple"
        case .amethystHaze: "Amethyst Haze"
        case .emberAmber: "Ember Amber"
        case .blueCurrent: "Blue Current"
        case .roseQuartz: "Rose Quartz"
        case .whyNab: "Why Nab"
        }
    }
}

struct ActualistThemePalette {
    let background: Color
    let surface: Color
    let elevatedSurface: Color
    let control: Color
    let accent: Color
    let positive: Color
    let warning: Color
    let danger: Color
    let neutral: Color
    let primaryText: Color
    let secondaryText: Color
    let separator: Color

    init(
        background: Color,
        surface: Color,
        elevatedSurface: Color,
        control: Color,
        accent: Color,
        positive: Color,
        warning: Color,
        danger: Color,
        neutral: Color = Color.gray.opacity(0.45),
        primaryText: Color,
        secondaryText: Color,
        separator: Color
    ) {
        self.background = background
        self.surface = surface
        self.elevatedSurface = elevatedSurface
        self.control = control
        self.accent = accent
        self.positive = positive
        self.warning = warning
        self.danger = danger
        self.neutral = neutral
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.separator = separator
    }
}

enum ActualistTheme {
    static var background: Color { current.background }
    static var surface: Color { current.surface }
    static var elevatedSurface: Color { current.elevatedSurface }
    static var control: Color { current.control }
    static var accent: Color { current.accent }
    static var positive: Color { current.positive }
    static var warning: Color { current.warning }
    static var danger: Color { current.danger }
    static var neutral: Color { current.neutral }
    static var primaryText: Color { current.primaryText }
    static var secondaryText: Color { current.secondaryText }
    static var separator: Color { current.separator }

    static func activate(_ option: ActualistThemeOption) {
        activeOption = option
    }

    static func palette(for option: ActualistThemeOption) -> ActualistThemePalette {
        switch option {
        case .actualPurple:
            return ActualistThemePalette(
                background: Color(hex: 0x0A0710),
                surface: Color(hex: 0x14101D),
                elevatedSurface: Color(hex: 0x1D1429),
                control: Color(hex: 0x25183A),
                accent: Color(hex: 0x7E65A8),
                positive: Self.whyNabPalette.positive,
                warning: Self.whyNabPalette.warning,
                danger: Self.whyNabPalette.danger,
                primaryText: Color(hex: 0xF9F6FE),
                secondaryText: Color(hex: 0xC7B6DF),
                separator: Color(hex: 0x7E65A8).opacity(0.16)
            )
        case .amethystHaze:
            return ActualistThemePalette(
                background: Color(hex: 0x050313),
                surface: Color(hex: 0x100D24),
                elevatedSurface: Color(hex: 0x191337),
                control: Color(hex: 0x241A43),
                accent: Color(hex: 0x8B68E8),
                positive: Color(hex: 0x9671F0),
                warning: Color(hex: 0xD7B55D),
                danger: Color(hex: 0xD95F7B),
                neutral: Color(hex: 0x2F2948),
                primaryText: Color(hex: 0xF8F5FF),
                secondaryText: Color(hex: 0xBFB2E3),
                separator: Color(hex: 0x8B68E8).opacity(0.18)
            )
        case .emberAmber:
            return ActualistThemePalette(
                background: Color(hex: 0x0E0D10),
                surface: Color(hex: 0x19161B),
                elevatedSurface: Color(hex: 0x241A20),
                control: Color(hex: 0x30232A),
                accent: Color(hex: 0xE4A258),
                positive: Color(hex: 0xE2A15A),
                warning: Color(hex: 0xF0C86D),
                danger: Color(hex: 0xA84C61),
                neutral: Color(hex: 0x543040),
                primaryText: Color(hex: 0xF8F4F0),
                secondaryText: Color(hex: 0xD1B9AA),
                separator: Color(hex: 0xE4A258).opacity(0.14)
            )
        case .blueCurrent:
            return ActualistThemePalette(
                background: Color(hex: 0x020B13),
                surface: Color(hex: 0x071A26),
                elevatedSurface: Color(hex: 0x0B2231),
                control: Color(hex: 0x102D41),
                accent: Color(hex: 0x4B84BE),
                positive: Color(hex: 0x477FB6),
                warning: Color(hex: 0xC9A85A),
                danger: Color(hex: 0xC85D68),
                neutral: Color(hex: 0x1B3144),
                primaryText: Color(hex: 0xF2F8FF),
                secondaryText: Color(hex: 0x9DB9CF),
                separator: Color(hex: 0x4B84BE).opacity(0.15)
            )
        case .roseQuartz:
            return ActualistThemePalette(
                background: Color(hex: 0x111113),
                surface: Color(hex: 0x1C1A1F),
                elevatedSurface: Color(hex: 0x241E25),
                control: Color(hex: 0x302631),
                accent: Color(hex: 0xC47D90),
                positive: Color(hex: 0xB97689),
                warning: Color(hex: 0xD4A15F),
                danger: Color(hex: 0xD96D79),
                neutral: Color(hex: 0x403943),
                primaryText: Color(hex: 0xF8F3F4),
                secondaryText: Color(hex: 0xD0B7BF),
                separator: Color(hex: 0xC47D90).opacity(0.14)
            )
        case .whyNab:
            return whyNabPalette
        }
    }

    private static let whyNabPalette = ActualistThemePalette(
        background: Color(red: 0.02, green: 0.02, blue: 0.05),
        surface: Color(red: 0.07, green: 0.07, blue: 0.15),
        elevatedSurface: Color(red: 0.10, green: 0.10, blue: 0.19),
        control: Color(red: 0.17, green: 0.17, blue: 0.24),
        accent: Color(red: 0.49, green: 0.52, blue: 1.00),
        positive: Color(red: 0.55, green: 0.78, blue: 0.24),
        warning: Color(red: 0.95, green: 0.78, blue: 0.28),
        danger: Color(red: 0.90, green: 0.29, blue: 0.33),
        primaryText: Color(red: 0.96, green: 0.96, blue: 0.99),
        secondaryText: Color(red: 0.72, green: 0.73, blue: 0.78),
        separator: Color.white.opacity(0.10)
    )

    private static var activeOption: ActualistThemeOption = .actualPurple

    private static var current: ActualistThemePalette {
        palette(for: activeOption)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

enum ActualistDisplayDensity: String, Codable, CaseIterable, Identifiable {
    case dense
    case compact
    case comfortable
    case large

    var id: String { rawValue }

    var sliderValue: Double {
        switch self {
        case .dense: 0
        case .compact: 1
        case .comfortable: 2
        case .large: 3
        }
    }

    init(sliderValue: Double) {
        switch Int(sliderValue.rounded()) {
        case 0:
            self = .dense
        case 1:
            self = .compact
        case 2:
            self = .comfortable
        default:
            self = .large
        }
    }

    var title: String {
        switch self {
        case .dense: "Dense"
        case .compact: "Compact"
        case .comfortable: "Comfortable"
        case .large: "Large"
        }
    }

    var workScreenAmountSize: CGFloat {
        switch self {
        case .comfortable: 24
        case .compact: 22
        case .dense: 20
        case .large: 26
        }
    }

    var editorAmountSize: CGFloat {
        switch self {
        case .comfortable: 46
        case .compact: 42
        case .dense: 38
        case .large: 50
        }
    }

    var transactionAmountSize: CGFloat {
        switch self {
        case .dense: 18
        case .compact: 21
        case .comfortable: 23
        case .large: 26
        }
    }

    var transactionClearedIconSize: CGFloat {
        switch self {
        case .dense: 15
        case .compact: 17
        case .comfortable: 18
        case .large: 20
        }
    }

    var rowHorizontalPadding: CGFloat {
        switch self {
        case .comfortable: 18
        case .compact: 16
        case .dense: 14
        case .large: 20
        }
    }

    var accountRowVerticalPadding: CGFloat {
        switch self {
        case .comfortable: 16
        case .compact: 14
        case .dense: 11
        case .large: 18
        }
    }

    var transactionRowVerticalPadding: CGFloat {
        switch self {
        case .comfortable: 14
        case .compact: 12
        case .dense: 10
        case .large: 16
        }
    }

    var editorRowVerticalPadding: CGFloat {
        switch self {
        case .comfortable: 16
        case .compact: 14
        case .dense: 12
        case .large: 18
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .comfortable: 38
        case .compact: 36
        case .dense: 32
        case .large: 40
        }
    }
}

enum ActualistTypography {
    static func workScreenAmount(for density: ActualistDisplayDensity) -> Font {
        .system(size: density.workScreenAmountSize, weight: .bold, design: .rounded)
    }

    static func editorAmount(for density: ActualistDisplayDensity) -> Font {
        .system(size: density.editorAmountSize, weight: .bold, design: .rounded)
    }

    static func transactionAmount(for density: ActualistDisplayDensity) -> Font {
        .system(size: density.transactionAmountSize, weight: .bold, design: .rounded)
    }

    static func sectionTitle(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large: .title3.weight(.bold)
        case .comfortable, .compact: .headline.weight(.bold)
        case .dense: .subheadline.weight(.bold)
        }
    }

    static func rowTitle(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large: .title3.weight(.semibold)
        case .comfortable: .body.weight(.semibold)
        case .compact: .callout.weight(.semibold)
        case .dense: .subheadline.weight(.semibold)
        }
    }

    static func rowValue(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large: .title3.weight(.bold)
        case .comfortable: .headline.weight(.bold)
        case .compact: .subheadline.weight(.bold)
        case .dense: .footnote.weight(.bold)
        }
    }

    static func rowLabel(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large: .callout.weight(.medium)
        case .comfortable, .compact: .caption.weight(.medium)
        case .dense: .caption2.weight(.medium)
        }
    }

    static func rowBadge(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large: .callout.weight(.semibold)
        case .comfortable, .compact: .caption.weight(.semibold)
        case .dense: .caption2.weight(.semibold)
        }
    }

    static func control(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large: .body.weight(.bold)
        case .comfortable: .callout.weight(.bold)
        case .compact: .subheadline.weight(.bold)
        case .dense: .footnote.weight(.bold)
        }
    }

    static func body(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large: .body.weight(.medium)
        case .comfortable: .body.weight(.medium)
        case .compact: .callout.weight(.medium)
        case .dense: .subheadline.weight(.medium)
        }
    }

    static func keypadDigit(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large: .system(size: 34, weight: .regular, design: .rounded)
        case .comfortable: .system(size: 32, weight: .regular, design: .rounded)
        case .compact: .system(size: 29, weight: .regular, design: .rounded)
        case .dense: .system(size: 26, weight: .regular, design: .rounded)
        }
    }

    static func keypadSymbol(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large: .system(size: 29, weight: .semibold, design: .rounded)
        case .comfortable: .system(size: 27, weight: .semibold, design: .rounded)
        case .compact: .system(size: 24, weight: .semibold, design: .rounded)
        case .dense: .system(size: 22, weight: .semibold, design: .rounded)
        }
    }
}

private struct ActualistDisplayDensityKey: EnvironmentKey {
    static let defaultValue: ActualistDisplayDensity = .compact
}

extension EnvironmentValues {
    var actualistDensity: ActualistDisplayDensity {
        get { self[ActualistDisplayDensityKey.self] }
        set { self[ActualistDisplayDensityKey.self] = newValue }
    }
}

extension View {
    func actualistScreenBackground() -> some View {
        background(ActualistTheme.background.ignoresSafeArea())
    }

    func glassControlCapsule() -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular.tint(ActualistTheme.control.opacity(0.34)), in: Capsule())
    }

    func actualistToolbarGlassButton() -> some View {
        self
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .tint(.white)
            .controlSize(.small)
    }
}
