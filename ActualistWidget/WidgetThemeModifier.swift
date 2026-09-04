import SwiftUI
import WidgetKit

private struct WidgetPaletteKey: EnvironmentKey {
    static let defaultValue = WidgetPalette(theme: .actualPurple, renderingMode: .fullColor)
}

extension EnvironmentValues {
    var widgetPalette: WidgetPalette {
        get { self[WidgetPaletteKey.self] }
        set { self[WidgetPaletteKey.self] = newValue }
    }
}

private struct WidgetThemeModifier: ViewModifier {
    let theme: ActualistThemeOption
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let palette = WidgetPalette(theme: theme, renderingMode: renderingMode)
        content
            .foregroundStyle(palette.primaryText)
            .tint(palette.accent)
            .environment(\.widgetPalette, palette)
            .containerBackground(for: .widget) { theme.palette.background }
            .environment(\.colorScheme, palette.usesThemeColors ? theme.colorScheme : colorScheme)
    }
}

extension View {
    func widgetTheme(_ theme: ActualistThemeOption) -> some View {
        modifier(WidgetThemeModifier(theme: theme))
    }
}
