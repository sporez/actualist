import Charts
import SwiftUI
import WidgetKit

struct MonthOverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.monthOverview, provider: BudgetSummaryTimelineProvider()) {
            MonthOverviewWidgetView(entry: $0).widgetTheme($0.theme)
        }
        .configurationDisplayName("Month Overview")
        .description("Income, spending, and money left to budget this month.")
        .supportedFamilies(WidgetSizeSupport.home + [.accessoryInline, .accessoryRectangular])
    }
}

struct MonthOverviewWidgetView: View {
    @Environment(\.widgetPalette) private var palette
    let entry: BudgetSummaryEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        WidgetSummaryShell(title: "Month Overview", snapshot: entry.snapshot, destination: WidgetDeepLink.url(.quickAction(.budget))) { snapshot in
            if let overview = snapshot.overview {
                if family == .accessoryInline {
                    Text("To budget: \(overview.toBudget.formatted)")
                } else if family == .accessoryRectangular {
                    metric("To Budget", overview.toBudget)
                } else if family == .systemSmall && typeSize.isAccessibilitySize {
                    metric("To Budget", overview.toBudget)
                } else if family == .systemSmall {
                    VStack(alignment: .leading, spacing: 6) {
                        compactMetric("Income", overview.income)
                        compactMetric("Spent", overview.spent)
                        compactMetric("To Budget", overview.toBudget)
                    }
                } else {
                    HStack(alignment: .top) {
                        metric("Income", overview.income)
                        Spacer(minLength: 8)
                        metric("Spent", overview.spent)
                        Spacer(minLength: 8)
                        metric("To Budget", overview.toBudget)
                    }
                    if family != .systemMedium {
                        Divider().padding(.vertical, 8)
                        HStack {
                            metric("Budgeted", overview.budgeted)
                            Spacer()
                            metric("Available", overview.available)
                        }
                        Chart {
                            BarMark(x: .value("Flow", "Income"), y: .value("Amount", overview.income.minorUnits))
                                .foregroundStyle(palette.positive)
                            BarMark(x: .value("Flow", "Spent"), y: .value("Amount", overview.spent.minorUnits))
                                .foregroundStyle(palette.accent)
                        }
                        .chartYAxis(.hidden)
                        .accessibilityLabel("Income \(overview.income.formatted), spent \(overview.spent.formatted)")
                        .widgetAccentable()
                        Text("\(snapshot.month) · \(snapshot.budgetName)")
                            .font(.caption).foregroundStyle(palette.secondaryText).lineLimit(2)
                        if !typeSize.isAccessibilitySize {
                            Text("Available includes money carried over from previous months.")
                                .font(.caption).foregroundStyle(palette.secondaryText)
                        }
                    }
                }
            } else {
                WidgetEmptyView(title: "Refresh month")
            }
        }
    }

    private func metric(_ label: String, _ amount: WidgetMoney) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(palette.secondaryText).lineLimit(1).minimumScaleFactor(0.6)
            Text(amount.formatted).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(palette.color(amount.tone))
        }
    }
    private func compactMetric(_ label: String, _ amount: WidgetMoney) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer(minLength: 3)
            Text(amount.formatted).font(.caption.bold()).monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
        }
    }
}
