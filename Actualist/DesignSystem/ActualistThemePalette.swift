import SwiftUI

enum ActualistThemeOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case actualPurple
    case actualPurpleLight
    case coastalSageLight
    case amethystHaze
    case emberAmber
    case blueCurrent
    case roseQuartz
    case whyNab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .actualPurple: "Actual Purple (dark)"
        case .actualPurpleLight: "Actual Purple (light)"
        case .coastalSageLight: "Coastal Sage (light)"
        case .amethystHaze: "Amethyst Haze (dark)"
        case .emberAmber: "Ember Amber (dark)"
        case .blueCurrent: "Blue Current (dark)"
        case .roseQuartz: "Rose Quartz (dark)"
        case .whyNab: "Why Nab (dark)"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .actualPurpleLight, .coastalSageLight: .light
        default: .dark
        }
    }

    var incomeTransactionAmount: Color {
        colorScheme == .light ? Color(hex: 0x247A3D) : Color(hex: 0x63D68A)
    }

    var palette: ActualistThemePalette {
        switch self {
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
        case .actualPurpleLight:
            return ActualistThemePalette(
                background: Color(hex: 0xECE5F3),
                surface: Color(hex: 0xFCFAFE),
                elevatedSurface: Color(hex: 0xDED3E9),
                control: Color(hex: 0xD1C1DF),
                accent: Color(hex: 0x624183),
                positive: Color(hex: 0x3F742E),
                warning: Color(hex: 0x8A5908),
                danger: Color(hex: 0xB33A4A),
                neutral: Color(hex: 0x91849D),
                primaryText: Color(hex: 0x211629),
                secondaryText: Color(hex: 0x5B4B67),
                positiveForeground: .white,
                separator: Color(hex: 0x624183).opacity(0.30)
            )
        case .coastalSageLight:
            return ActualistThemePalette(
                background: Color(hex: 0xE4EFEB),
                surface: Color(hex: 0xFBFEFD),
                elevatedSurface: Color(hex: 0xD2E3DD),
                control: Color(hex: 0xC1D9D1),
                accent: Color(hex: 0x1F6B64),
                positive: Color(hex: 0x28663F),
                warning: Color(hex: 0x8C5908),
                danger: Color(hex: 0xB84E4B),
                neutral: Color(hex: 0x81978F),
                primaryText: Color(hex: 0x102925),
                secondaryText: Color(hex: 0x45615B),
                positiveForeground: Color(hex: 0xF2FAF7),
                warningForeground: Color(hex: 0xFFF6E5),
                dangerForeground: Color(hex: 0xFFF5F3),
                neutralForeground: Color(hex: 0xF2FAF7),
                separator: Color(hex: 0x1F6B64).opacity(0.30)
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
            return Self.whyNabPalette
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

}

struct ActualistThemePalette: Sendable {
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
    let positiveForeground: Color
    let warningForeground: Color
    let dangerForeground: Color
    let neutralForeground: Color
    let separator: Color
    let chromeForeground: Color

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
        positiveForeground: Color = .black.opacity(0.78),
        warningForeground: Color = .black.opacity(0.78),
        dangerForeground: Color = .white,
        neutralForeground: Color? = nil,
        separator: Color,
        chromeForeground: Color? = nil
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
        self.positiveForeground = positiveForeground
        self.warningForeground = warningForeground
        self.dangerForeground = dangerForeground
        self.neutralForeground = neutralForeground ?? .white
        self.separator = separator
        self.chromeForeground = chromeForeground ?? primaryText
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
