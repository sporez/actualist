import SwiftUI
import WidgetKit

struct QuickActionsRow: View {
    @Environment(\.widgetPalette) private var palette
    let actions: [WidgetQuickAction]
    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(actions) { action in
                Link(destination: WidgetDeepLink.url(.quickAction(action))) { actionLabel(action) }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func actionLabel(_ action: WidgetQuickAction) -> some View {
        VStack(spacing: 10) {
            Image(systemName: action.symbol)
                .font(.title2.weight(.semibold))
                .frame(height: 36)
                .foregroundStyle(palette.accent)
                .widgetAccentable()
            Text(action.title)
                .font(.caption2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .foregroundStyle(palette.primaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.title)
    }
}
