import Charts
import SwiftUI
import WidgetKit

struct NetWorthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.netWorth, provider: BudgetSummaryTimelineProvider()) {
            NetWorthWidgetView(entry: $0).widgetTheme($0.appearance)
        }
        .configurationDisplayName("Net Worth")
        .description("Your net worth and its trend over the last six months.")
        .supportedFamilies(WidgetSizeSupport.home + [.accessoryInline, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct NetWorthWidgetView: View {
    @Environment(\.widgetPalette) private var palette
    let entry: BudgetSummaryEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        WidgetSummaryShell(snapshot: entry.snapshot, now: entry.date, destination: WidgetDeepLink.url(.quickAction(.reports)), margin: WidgetPlateMetrics.contentMargin) { snapshot in
            if let worth = snapshot.netWorth {
                switch family {
                case .accessoryInline:
                    Text("Net worth: \(worth.balance.formatted)")
                case .accessoryRectangular:
                    summary(worth)
                default:
                    VStack(spacing: 0) {
                        summary(worth)
                            .padding(.horizontal, WidgetPlateMetrics.contentMargin)
                            .padding(.top, 14)
                        chart(worth)
                    }
                }
            } else {
                WidgetEmptyView(title: "Nothing to Show Yet", margin: WidgetPlateMetrics.contentMargin)
            }
        }
    }

    private var heroFont: Font {
        switch family {
        case .accessoryRectangular: .headline
        case .systemSmall: .widgetHero(26)
        case .systemMedium: .widgetHero(30)
        case .systemLarge: .widgetHero(38)
        default: .widgetHero(46)
        }
    }

    private func summary(_ worth: WidgetNetWorthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !WidgetSizeSupport.isAccessory(family) {
                Text("Net Worth").font(.caption.weight(.semibold)).foregroundStyle(palette.secondaryText)
            }
            Text(worth.balance.formatted).font(heroFont).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            if family != .systemSmall || !typeSize.isAccessibilitySize {
                Label("\(worth.changeText) in \(worth.period)", systemImage: worth.change.minorUnits < 0 ? "arrow.down.right" : "arrow.up.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(palette.color(worth.change.tone))
                    .labelStyle(.titleAndIcon).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var showsMonths: Bool {
        WidgetSizeSupport.size(family) != .small && family != .systemMedium && !typeSize.isAccessibilitySize
    }

    private func chart(_ worth: WidgetNetWorthSnapshot) -> some View {
        let domain = worth.chartDomain
        return Chart(worth.points) { point in
            AreaMark(
                x: .value("Date", point.date),
                yStart: .value("Floor", domain.lowerBound),
                yEnd: .value("Net Worth", point.amount.minorUnits)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(LinearGradient(
                colors: [palette.accent.opacity(0.55), palette.accent.opacity(0.02)],
                startPoint: .top, endPoint: .bottom
            ))
            LineMark(x: .value("Date", point.date), y: .value("Net Worth", point.amount.minorUnits))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(palette.accent)
            if point.id == worth.points.last?.id {
                PointMark(x: .value("Date", point.date), y: .value("Net Worth", point.amount.minorUnits))
                    .symbolSize(70)
                    .foregroundStyle(palette.primaryText)
            }
        }
        .chartYAxis(.hidden)
        .chartXAxis(showsMonths ? .automatic : .hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .chartYScale(domain: domain)
        .chartXScale(range: .plotDimension(startPadding: 0, endPadding: 12))
        .accessibilityLabel("Net worth trend over \(worth.period)")
        .widgetAccentable()
    }
}
