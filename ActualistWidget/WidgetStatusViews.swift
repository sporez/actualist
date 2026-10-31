import SwiftUI
import WidgetKit

enum WidgetPlateMetrics {
    static let inset: CGFloat = 6
    static let detailVertical: CGFloat = 12
    /// Replaces the system margin for text in widgets that disable it for a plate.
    static let contentMargin: CGFloat = 16
}

extension Font {
    static func widgetHero(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }
}

/// The Budget screen's To Budget banner as a widget block. `ContainerRelativeShape`
/// keeps its corners concentric with the widget's, whatever the size.
struct WidgetStatusPlate<Content: View>: View {
    @Environment(\.widgetPalette) private var palette
    let status: WidgetStatus
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .foregroundStyle(palette.plateForeground(status))
            .background {
                if let fill = palette.plateFill(status) {
                    ContainerRelativeShape().fill(fill)
                }
            }
    }
}

/// Places a plate and its details for each widget size: stacked when tall,
/// side by side when wide.
struct WidgetPlateLayout<Plate: View, Details: View>: View {
    @Environment(\.widgetFamily) private var family
    @ViewBuilder let plate: () -> Plate
    @ViewBuilder let details: () -> Details

    var body: some View {
        if family == .systemMedium || family == .systemExtraLarge {
            HStack(spacing: 0) {
                plate()
                    .padding(WidgetPlateMetrics.inset)
                    .frame(maxWidth: .infinity)
                details()
                    .padding(.vertical, WidgetPlateMetrics.detailVertical)
                    .padding(.leading, 6)
                    .padding(.trailing, WidgetPlateMetrics.contentMargin)
                    .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                plate()
                    .padding(WidgetPlateMetrics.inset)
                    .frame(height: plateHeight)
                details()
                    .padding(.top, 2)
                    .padding(.horizontal, WidgetPlateMetrics.contentMargin)
                    .padding(.bottom, WidgetPlateMetrics.detailVertical)
            }
        }
    }

    private var plateHeight: CGFloat {
        switch family {
        case .systemSmall: 92
        case .systemLarge: 148
        default: 208
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
