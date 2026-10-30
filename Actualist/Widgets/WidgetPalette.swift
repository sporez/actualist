import SwiftUI
import WidgetKit

struct WidgetPalette: Sendable {
    let theme: ActualistThemeOption
    let usesThemeColors: Bool

    init(theme: ActualistThemeOption, renderingMode: WidgetRenderingMode) {
        self.theme = theme
        usesThemeColors = renderingMode == .fullColor
    }

    private var colors: ActualistThemePalette { theme.palette }
    var primaryText: Color { usesThemeColors ? colors.primaryText : .primary }
    var secondaryText: Color { usesThemeColors ? colors.secondaryText : .secondary }
    var accent: Color { usesThemeColors ? colors.accent : .primary }
    var positive: Color { usesThemeColors ? colors.positive : .primary }
    var danger: Color { usesThemeColors ? colors.danger : .primary }

    var track: Color { primaryText.opacity(0.14) }

    func color(_ tone: WidgetAmountTone) -> Color {
        switch tone {
        case .positive: positive
        case .zero: secondaryText
        case .negative: danger
        }
    }

    /// Nil outside full color, where the system owns the widget's tint.
    func plateFill(_ tone: WidgetAmountTone) -> Color? {
        guard usesThemeColors else { return nil }
        return switch tone {
        case .positive: colors.positive
        case .zero: colors.neutral
        case .negative: colors.danger
        }
    }

    func plateForeground(_ tone: WidgetAmountTone) -> Color {
        guard usesThemeColors else { return .primary }
        return switch tone {
        case .positive: colors.positiveForeground
        case .zero: colors.neutralForeground
        case .negative: colors.dangerForeground
        }
    }
}
