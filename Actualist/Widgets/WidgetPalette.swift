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

    func color(_ tone: WidgetAmountTone) -> Color {
        switch tone {
        case .positive: positive
        case .zero: secondaryText
        case .negative: danger
        }
    }
}
