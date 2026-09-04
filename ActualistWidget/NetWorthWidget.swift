import Charts
import SwiftUI
import WidgetKit

struct NetWorthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.netWorth, provider: BudgetSummaryTimelineProvider()) {
            NetWorthWidgetView(entry: $0).widgetTheme($0.theme)
        }
        .configurationDisplayName("Net Worth")
        .description("Your net worth and its trend over the last six months.")
        .supportedFamilies(WidgetSizeSupport.home + [.accessoryInline, .accessoryRectangular])
    }
}

struct NetWorthWidgetView: View {
    @Environment(\.widgetPalette) private var palette
    let entry: BudgetSummaryEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        WidgetSummaryShell(title: "Net Worth", snapshot: entry.snapshot, destination: WidgetDeepLink.url(.quickAction(.reports))) { snapshot in
            if let worth = snapshot.netWorth {
                if family == .accessoryInline {
                    Text("Net worth: \(worth.balance.formatted)")
                } else {
                    Text(worth.balance.formatted).font(.title2.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    if family != .systemSmall || !typeSize.isAccessibilitySize {
                        Label("\(worth.change.formatted) · \(worth.period)", systemImage: worth.change.minorUnits < 0 ? "arrow.down.right" : "arrow.up.right")
                            .font(.caption).foregroundStyle(palette.color(worth.change.tone)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    if !WidgetSizeSupport.isAccessory(family) {
                        Chart(worth.points) { point in
                            LineMark(x: .value("Date", point.date), y: .value("Net Worth", point.amount.minorUnits))
                                .foregroundStyle(palette.accent)
                        }
                        .chartYAxis(.hidden)
                        .chartXAxis(family == .systemSmall || typeSize.isAccessibilitySize ? .hidden : .automatic)
                        .chartYScale(domain: .automatic(includesZero: false))
                        .accessibilityLabel("Net worth trend over \(worth.period)")
                        .widgetAccentable()
                    }
                }
            } else {
                WidgetEmptyView(title: "Refresh net worth")
            }
        }
    }
}
