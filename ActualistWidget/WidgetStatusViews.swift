import SwiftUI
import WidgetKit

/// The Budget screen's To Budget banner as a widget block. `ContainerRelativeShape`
/// keeps its corners concentric with the widget's, whatever the size.
struct WidgetStatusPlate<Content: View>: View {
    @Environment(\.widgetPalette) private var palette
    let tone: WidgetAmountTone
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .foregroundStyle(palette.plateForeground(tone))
            .background {
                if let fill = palette.plateFill(tone) {
                    ContainerRelativeShape().fill(fill)
                }
            }
    }
}

/// Budget used, with a tick for how far through the month today is.
struct WidgetMonthMeter: View {
    @Environment(\.widgetPalette) private var palette
    let progress: WidgetMonthProgress
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let filled = proxy.size.width * progress.spentFraction
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)
                if filled > 0 {
                    Capsule()
                        .fill(progress.isOverBase ? palette.danger : palette.accent)
                        .frame(width: max(filled, height))
                        .widgetAccentable()
                }
                RoundedRectangle(cornerRadius: 1)
                    .fill(palette.primaryText)
                    .frame(width: 2, height: height + 6)
                    .offset(x: tickOffset(in: proxy.size.width))
            }
            .frame(height: proxy.size.height)
        }
        .frame(height: height + 6)
        .accessibilityElement()
        .accessibilityLabel("Spent \(progress.spentShareText) of the month's \(progress.base == .budgeted ? "budget" : "income")")
        .accessibilityValue(progress.daysLeftText)
    }

    private func tickOffset(in width: CGFloat) -> CGFloat {
        min(max(width * progress.monthFraction - 1, 0), width - 2)
    }
}
