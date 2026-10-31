import SwiftUI
import WidgetKit

struct QuickActionsRow: View {
    @Environment(\.widgetPalette) private var palette
    let actions: [WidgetQuickAction]
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(actions) { action in
                Link(destination: WidgetDeepLink.url(.quickAction(action))) { actionLabel(action) }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func actionLabel(_ action: WidgetQuickAction) -> some View {
        VStack(spacing: 8) {
            Image(systemName: action.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.primaryText)
                .frame(width: 52, height: 52)
                .background(palette.accent.opacity(0.35), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .widgetAccentable()
            Text(action.title)
                .font(.caption2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .foregroundStyle(palette.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.title)
    }
}
