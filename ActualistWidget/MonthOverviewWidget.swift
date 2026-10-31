import SwiftUI
import WidgetKit

struct MonthOverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.monthOverview, provider: BudgetSummaryTimelineProvider()) {
            MonthOverviewWidgetView(entry: $0).widgetTheme($0.theme)
        }
        .configurationDisplayName("Month Overview")
        .description("How much is left to budget, and how this month's spending is going.")
        .supportedFamilies(WidgetSizeSupport.home + [.accessoryInline, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct MonthOverviewWidgetView: View {
    @Environment(\.widgetPalette) private var palette
    let entry: BudgetSummaryEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        WidgetSummaryShell(snapshot: entry.snapshot, now: entry.date, destination: WidgetDeepLink.url(.quickAction(.budget)), margin: WidgetPlateMetrics.contentMargin) { snapshot in
            if let overview = snapshot.overview, let summary = overview.displayedSummary {
                switch family {
                case .accessoryInline:
                    Text("\(summary.kind.title): \(summary.amount.formatted)")
                case .accessoryRectangular:
                    accessory(summary, progress: progress(overview))
                default:
                    home(snapshot, overview, summary)
                }
            } else {
                WidgetEmptyView(title: "Nothing to Show Yet", margin: WidgetPlateMetrics.contentMargin)
            }
        }
    }

    private func progress(_ overview: WidgetMonthOverviewSnapshot) -> WidgetMonthProgress? {
        WidgetMonthProgress(
            spent: overview.spent.minorUnits, budgeted: overview.budgeted.minorUnits,
            income: overview.income.minorUnits, now: entry.date, calendar: WidgetMonthID.gregorianCalendar()
        )
    }

    private func accessory(_ summary: WidgetSummaryMetric, progress: WidgetMonthProgress?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.kind.title).font(.caption.weight(.medium)).foregroundStyle(palette.secondaryText)
            Text(summary.amount.formatted).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            if let progress { WidgetMonthMeter(progress: progress, height: 4) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Home Screen

    @ViewBuilder private func home(
        _ snapshot: WidgetSnapshot, _ overview: WidgetMonthOverviewSnapshot, _ summary: WidgetSummaryMetric
    ) -> some View {
        if family == .systemSmall && typeSize.isAccessibilitySize {
            plate(snapshot, summary)
                .padding(WidgetPlateMetrics.inset)
        } else {
            WidgetPlateLayout {
                plate(snapshot, summary)
            } details: {
                details(overview, progress(overview))
            }
        }
    }

    /// Sizes tall enough for the Budget screen's list rows.
    private var usesRows: Bool { WidgetSizeSupport.size(family) != .small && family != .systemMedium }

    private var heroFont: Font {
        switch family {
        case .systemSmall: .widgetHero(30)
        case .systemMedium: .widgetHero(40)
        case .systemLarge: .widgetHero(56)
        default: .widgetHero(76)
        }
    }

    private func plate(_ snapshot: WidgetSnapshot, _ summary: WidgetSummaryMetric) -> some View {
        WidgetStatusPlate(status: WidgetStatus(summary.amount.tone)) {
            VStack(alignment: .leading, spacing: 0) {
                if family != .systemSmall, let month = WidgetMonthID.displayName(snapshot.month) {
                    Text(month).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                }
                Text(summary.kind.title).font(.caption.weight(.semibold)).opacity(0.75)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(summary.amount.formatted).font(heroFont).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.4)
                    .widgetAccentable()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    @ViewBuilder private func details(
        _ overview: WidgetMonthOverviewSnapshot, _ progress: WidgetMonthProgress?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if family == .systemMedium { Spacer(minLength: 0) }
            spending(overview, progress)
                .padding(.top, usesRows ? 8 : 0)
            if usesRows {
                rows(overview)
                    .padding(.top, 8)
            } else if family == .systemMedium && !typeSize.isAccessibilitySize {
                Spacer(minLength: 8)
                totals(overview)
            }
        }
    }

    private func rows(_ overview: WidgetMonthOverviewSnapshot) -> some View {
        VStack(spacing: 0) {
            row("Income", overview.income)
            Divider()
            row("Budgeted", overview.budgeted)
            Divider()
            row(overview.balanceLabel, overview.available)
        }
    }

    private func row(_ label: String, _ amount: WidgetMoney) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(palette.secondaryText)
            Spacer(minLength: 8)
            Text(amount.formatted).fontWeight(.semibold).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(amount.tone == .negative ? palette.danger : palette.primaryText)
        }
        .font(.subheadline)
        .frame(minHeight: 30, maxHeight: .infinity)
    }

    private func spending(_ overview: WidgetMonthOverviewSnapshot, _ progress: WidgetMonthProgress?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Spent").font(.caption.weight(.medium)).foregroundStyle(palette.secondaryText)
                Spacer(minLength: 4)
                Text(overview.spent.formatted).font(amountFont).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            if let progress {
                WidgetMonthMeter(progress: progress)
                if family != .systemSmall {
                    HStack {
                        Text(usesRows ? usedText(progress) : baseText(overview, progress))
                        Spacer(minLength: 4)
                        Text(progress.daysLeftText)
                    }
                    .font(.caption2).foregroundStyle(palette.secondaryText).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
    }

    private var amountFont: Font {
        family == .systemSmall ? .subheadline.weight(.semibold) : (usesRows ? .title2.weight(.semibold) : .title3.weight(.semibold))
    }

    private func baseText(_ overview: WidgetMonthOverviewSnapshot, _ progress: WidgetMonthProgress) -> String {
        switch progress.base {
        case .budgeted: "of \(overview.budgeted.formatted) budgeted"
        case .income: "of \(overview.income.formatted) income"
        }
    }

    private func usedText(_ progress: WidgetMonthProgress) -> String {
        "\(progress.spentShareText) of \(progress.base == .budgeted ? "budget" : "income")"
    }

    private func totals(_ overview: WidgetMonthOverviewSnapshot) -> some View {
        HStack(alignment: .top) {
            total("Income", overview.income, alignment: .leading)
            Spacer(minLength: 8)
            total(overview.balanceLabel, overview.available, alignment: .trailing)
        }
    }

    private func total(_ label: String, _ amount: WidgetMoney, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(palette.secondaryText)
            Text(amount.formatted).font(.footnote.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(amount.tone == .negative ? palette.danger : palette.primaryText)
        }
    }
}
