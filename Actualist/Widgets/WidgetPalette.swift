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
    var warning: Color { usesThemeColors ? colors.warning : .primary }
    var danger: Color { usesThemeColors ? colors.danger : .primary }

    var track: Color { primaryText.opacity(0.14) }

    func color(_ tone: WidgetAmountTone) -> Color {
        switch tone {
        case .positive: positive
        case .zero: secondaryText
        case .negative: danger
        }
    }

    /// Nil outside full color, where the system owns the widget's tint. Neutral is
    /// tinted from the text color because some themes' `neutral` carries a hue close
    /// to their danger color, which reads as overspent at this size.
    func plateFill(_ status: WidgetStatus) -> Color? {
        guard usesThemeColors else { return nil }
        return switch status {
        case .positive: colors.positive
        case .caution: colors.warning
        case .negative: colors.danger
        case .neutral: track
        }
    }

    func plateForeground(_ status: WidgetStatus) -> Color {
        guard usesThemeColors else { return .primary }
        return switch status {
        case .positive: colors.positiveForeground
        case .caution: colors.warningForeground
        case .negative: colors.dangerForeground
        case .neutral: colors.primaryText
        }
    }
}
