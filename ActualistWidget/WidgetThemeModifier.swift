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
    let appearance: ActualistAppearance
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        // Match System picks its slot from the scheme the system renders in.
        let theme = appearance.option(for: colorScheme)
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
    func widgetTheme(_ appearance: ActualistAppearance) -> some View {
        modifier(WidgetThemeModifier(appearance: appearance))
    }
}
