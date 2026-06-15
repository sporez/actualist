import SwiftUI

enum ActualistTheme {
    static let background = Color(red: 0.02, green: 0.02, blue: 0.05)
    static let surface = Color(red: 0.07, green: 0.07, blue: 0.15)
    static let elevatedSurface = Color(red: 0.10, green: 0.10, blue: 0.19)
    static let control = Color(red: 0.17, green: 0.17, blue: 0.24)
    static let accent = Color(red: 0.49, green: 0.52, blue: 1.00)
    static let positive = Color(red: 0.55, green: 0.78, blue: 0.24)
    static let warning = Color(red: 0.95, green: 0.78, blue: 0.28)
    static let danger = Color(red: 0.90, green: 0.29, blue: 0.33)
    static let primaryText = Color(red: 0.96, green: 0.96, blue: 0.99)
    static let secondaryText = Color(red: 0.72, green: 0.73, blue: 0.78)
    static let separator = Color.white.opacity(0.10)
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
        case .dense: 24
        case .compact: 28
        case .comfortable: 30
        case .large: 34
        }
    }

    var transactionClearedIconSize: CGFloat {
        switch self {
        case .dense: 20
        case .compact: 22
        case .comfortable: 24
        case .large: 26
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
            .controlSize(.small)
    }
}
