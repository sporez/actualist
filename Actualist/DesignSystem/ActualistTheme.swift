import os
import SwiftUI

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
    static var positiveForeground: Color { current.positiveForeground }
    static var warningForeground: Color { current.warningForeground }
    static var dangerForeground: Color { current.dangerForeground }
    static var neutralForeground: Color { current.neutralForeground }
    static var separator: Color { current.separator }
    static var chromeForeground: Color { current.chromeForeground }
    static var incomeTransactionAmount: Color { current.incomeTransactionAmount }

    /// Sync-status dot colors. They are the same in every theme.
    static let syncOnline = Color(red: 0.22, green: 0.82, blue: 0.38)
    static let syncPending = Color(red: 0.96, green: 0.76, blue: 0.20)
    static let syncOffline = Color(red: 0.95, green: 0.26, blue: 0.32)

    /// The Move Money header keeps this dark green in every theme.
    static let moveMoneyHeaderFill = Color(red: 0.14, green: 0.37, blue: 0.04)

    /// Corner radii shared across cards and panels.
    enum Radius {
        static let card: CGFloat = 18
        static let panel: CGFloat = 22
        static let sheetCard: CGFloat = 24
        static let control: CGFloat = 12
    }

    static func activate(_ appearance: ActualistAppearance) {
        let built = palette(for: appearance)
        active.withLock { $0 = built }
    }

    /// Palette selection is app-wide UI state. The lock makes reads safe from
    /// nonisolated color helpers while `AppState` still writes it on the main
    /// actor. It holds the built palette so a read never rebuilds colors.
    private static let active = OSAllocatedUnfairLock(
        initialState: palette(for: .fixed(.actualPurple))
    )

    private static var current: ActualistThemePalette {
        active.withLock { $0 }
    }

    private static func palette(for appearance: ActualistAppearance) -> ActualistThemePalette {
        switch appearance {
        case .fixed(let option): option.palette
        case .matchingSystem(let pair): .adaptive(light: pair.light.palette, dark: pair.dark.palette)
        }
    }
}

extension ActualistThemePalette {
    /// Each token resolves at draw time from the view's color scheme, so a
    /// system light/dark switch repaints without rebuilding any view.
    static func adaptive(light: ActualistThemePalette, dark: ActualistThemePalette) -> ActualistThemePalette {
        ActualistThemePalette(
            background: .adaptive(light: light.background, dark: dark.background),
            surface: .adaptive(light: light.surface, dark: dark.surface),
            elevatedSurface: .adaptive(light: light.elevatedSurface, dark: dark.elevatedSurface),
            control: .adaptive(light: light.control, dark: dark.control),
            accent: .adaptive(light: light.accent, dark: dark.accent),
            positive: .adaptive(light: light.positive, dark: dark.positive),
            warning: .adaptive(light: light.warning, dark: dark.warning),
            danger: .adaptive(light: light.danger, dark: dark.danger),
            neutral: .adaptive(light: light.neutral, dark: dark.neutral),
            primaryText: .adaptive(light: light.primaryText, dark: dark.primaryText),
            secondaryText: .adaptive(light: light.secondaryText, dark: dark.secondaryText),
            positiveForeground: .adaptive(light: light.positiveForeground, dark: dark.positiveForeground),
            warningForeground: .adaptive(light: light.warningForeground, dark: dark.warningForeground),
            dangerForeground: .adaptive(light: light.dangerForeground, dark: dark.dangerForeground),
            neutralForeground: .adaptive(light: light.neutralForeground, dark: dark.neutralForeground),
            incomeTransactionAmount: .adaptive(light: light.incomeTransactionAmount, dark: dark.incomeTransactionAmount),
            separator: .adaptive(light: light.separator, dark: dark.separator),
            chromeForeground: .adaptive(light: light.chromeForeground, dark: dark.chromeForeground)
        )
    }
}

extension Color {
    /// SwiftUI has no public light/dark color initializer, so this goes through
    /// a dynamic `UIColor`. It is a color value, not a UIKit view. An
    /// unspecified trait resolves dark, the app's default.
    static func adaptive(light: Color, dark: Color) -> Color {
        let light = UIColor(light)
        let dark = UIColor(dark)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .light ? light : dark
        })
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

    /// The next size up, for a line that should read slightly larger than
    /// ordinary rows; Large has no step above it.
    var oneStepLarger: ActualistDisplayDensity {
        switch self {
        case .dense: .compact
        case .compact: .comfortable
        case .comfortable, .large: .large
        }
    }

    var workScreenAmountSize: CGFloat {
        switch self {
        case .large: 24
        case .comfortable: 22
        case .compact: 20
        case .dense: 18
        }
    }

    var editorAmountSize: CGFloat {
        switch self {
        case .large: 46
        case .comfortable: 42
        case .compact: 38
        case .dense: 34
        }
    }

    var transactionAmountSize: CGFloat {
        switch self {
        case .large: 22
        case .comfortable: 20
        case .compact: 17
        case .dense: 14
        }
    }

    var transactionClearedIconSize: CGFloat {
        switch self {
        case .large: 17
        case .comfortable: 16
        case .compact: 14
        case .dense: 11
        }
    }

    var rowHorizontalPadding: CGFloat {
        switch self {
        case .large: 18
        case .comfortable: 16
        case .compact: 14
        case .dense: 11
        }
    }

    var accountRowVerticalPadding: CGFloat {
        switch self {
        case .large: 16
        case .comfortable: 14
        case .compact: 11
        case .dense: 8
        }
    }

    var transactionRowVerticalPadding: CGFloat {
        switch self {
        case .large: 14
        case .comfortable: 12
        case .compact: 10
        case .dense: 7
        }
    }

    var editorRowVerticalPadding: CGFloat {
        switch self {
        case .large: 16
        case .comfortable: 14
        case .compact: 12
        case .dense: 10
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .large: 38
        case .comfortable: 36
        case .compact: 32
        case .dense: 30
        }
    }
}

enum ActualistTypography {
    static func workScreenAmount(for density: ActualistDisplayDensity) -> Font {
        .system(size: density.workScreenAmountSize, weight: .bold, design: .rounded)
    }

    static func summarySecondaryAmount(for density: ActualistDisplayDensity) -> Font {
        .system(
            size: max(density.workScreenAmountSize - 4, 15),
            weight: .semibold,
            design: .rounded
        )
    }

    static func editorAmount(for density: ActualistDisplayDensity) -> Font {
        .system(size: density.editorAmountSize, weight: .bold, design: .rounded)
    }

    static func transactionAmount(for density: ActualistDisplayDensity) -> Font {
        .system(size: density.transactionAmountSize, weight: .bold, design: .rounded)
    }

    /// Fixed like `transactionAmount`, so the line under the amount never
    /// outgrows it at large text sizes.
    static func transactionRunningBalance(for density: ActualistDisplayDensity) -> Font {
        let size: CGFloat = switch density {
        case .large: 13
        case .comfortable: 12
        case .compact: 11
        case .dense: 10
        }
        return .system(size: size, weight: .semibold, design: .rounded)
    }

    static func sectionTitle(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large, .comfortable: .headline.weight(.bold)
        case .compact: .subheadline.weight(.bold)
        case .dense: .footnote.weight(.bold)
        }
    }

    static func rowTitle(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large: .body.weight(.semibold)
        case .comfortable: .callout.weight(.semibold)
        case .compact: .subheadline.weight(.semibold)
        case .dense: .footnote.weight(.semibold)
        }
    }

    static func rowValue(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large: .headline.weight(.bold)
        case .comfortable: .subheadline.weight(.bold)
        case .compact: .footnote.weight(.bold)
        case .dense: .caption.weight(.bold)
        }
    }

    static func rowLabel(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large, .comfortable: .caption.weight(.medium)
        case .compact: .caption2.weight(.medium)
        case .dense: .system(size: 10, weight: .medium)
        }
    }

    static func rowBadge(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large, .comfortable: .caption.weight(.semibold)
        case .compact: .caption2.weight(.semibold)
        case .dense: .system(size: 10, weight: .semibold)
        }
    }

    static func control(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large: .callout.weight(.bold)
        case .comfortable: .subheadline.weight(.bold)
        case .compact: .footnote.weight(.bold)
        case .dense: .caption.weight(.bold)
        }
    }

    static func body(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large: .body.weight(.medium)
        case .comfortable: .callout.weight(.medium)
        case .compact: .subheadline.weight(.medium)
        case .dense: .footnote.weight(.medium)
        }
    }

    /// Unweighted so Markdown **bold** can resolve to a heavier face.
    static func markdownBody(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large: .body
        case .comfortable: .callout
        case .compact: .subheadline
        case .dense: .footnote
        }
    }

    static func keypadDigit(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large: .system(size: 32, weight: .regular, design: .rounded)
        case .comfortable: .system(size: 29, weight: .regular, design: .rounded)
        case .compact: .system(size: 26, weight: .regular, design: .rounded)
        case .dense: .system(size: 24, weight: .regular, design: .rounded)
        }
    }

    static func keypadSymbol(for density: ActualistDisplayDensity) -> Font {
        switch density {
        case .large: .system(size: 27, weight: .semibold, design: .rounded)
        case .comfortable: .system(size: 24, weight: .semibold, design: .rounded)
        case .compact: .system(size: 22, weight: .semibold, design: .rounded)
        case .dense: .system(size: 20, weight: .semibold, design: .rounded)
        }
    }
}

/// A symbol glyph that grows with Dynamic Type like the text beside it.
/// Use it instead of a fixed `.font(.system(size:))`; a glyph inside a
/// fixed-size tile or beside a fixed-size amount stays fixed, with a comment.
private struct ScaledSymbolFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
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
    func actualistScaledSymbol(
        size: CGFloat,
        weight: Font.Weight,
        relativeTo style: Font.TextStyle
    ) -> some View {
        modifier(ScaledSymbolFont(size: size, weight: weight, relativeTo: style))
    }

    func actualistToolbarGlassButton() -> some View {
        self
            .font(.body.weight(.semibold))
            .foregroundStyle(ActualistTheme.chromeForeground)
            .tint(ActualistTheme.chromeForeground)
            .controlSize(.small)
    }

    /// A `List` row with no insets, separator or row background, for rows that
    /// draw their own card.
    func plainListRow() -> some View {
        self
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
