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
    static var incomeTransactionAmount: Color { activeOption.incomeTransactionAmount }

    static func activate(_ option: ActualistThemeOption) {
        activeOption = option
    }

    private static var activeOption: ActualistThemeOption = .actualPurple

    private static var current: ActualistThemePalette {
        activeOption.palette
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
            .foregroundStyle(ActualistTheme.chromeForeground)
            .tint(ActualistTheme.chromeForeground)
            .controlSize(.small)
    }
}
