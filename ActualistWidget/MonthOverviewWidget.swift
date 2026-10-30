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
        WidgetSummaryShell(snapshot: entry.snapshot, destination: WidgetDeepLink.url(.quickAction(.budget))) { snapshot in
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
                WidgetEmptyView(title: "Nothing to Show Yet", margin: 16)
            }
        }
    }

    private func progress(_ overview: WidgetMonthOverviewSnapshot) -> WidgetMonthProgress? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return WidgetMonthProgress(
            spent: overview.spent.minorUnits, budgeted: overview.budgeted.minorUnits,
            income: overview.income.minorUnits, now: entry.date, calendar: calendar
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

    private var isSideBySide: Bool { family == .systemMedium || family == .systemExtraLarge }

    @ViewBuilder private func home(
        _ snapshot: WidgetSnapshot, _ overview: WidgetMonthOverviewSnapshot, _ summary: WidgetSummaryMetric
    ) -> some View {
        let progress = progress(overview)
        if family == .systemSmall && typeSize.isAccessibilitySize {
            plate(snapshot, summary)
                .padding(WidgetPlateMetrics.inset)
        } else if isSideBySide {
            HStack(spacing: 0) {
                plate(snapshot, summary)
                    .padding(WidgetPlateMetrics.inset)
                    .frame(maxWidth: .infinity)
                details(snapshot, overview, progress)
                    .padding(.vertical, WidgetPlateMetrics.detailVertical)
                    .padding(.leading, 6)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                plate(snapshot, summary)
                    .padding(WidgetPlateMetrics.inset)
                    .frame(height: plateHeight)
                details(snapshot, overview, progress)
                    .padding(.top, 2)
                    .padding(.horizontal, 16)
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

    /// Sizes tall enough for the Budget screen's list rows.
    private var usesRows: Bool { WidgetSizeSupport.size(family) != .small && family != .systemMedium }

    private var heroFont: Font {
        let size: CGFloat = switch family {
        case .systemSmall: 26
        case .systemMedium: 30
        case .systemLarge: 44
        default: 52
        }
        return .system(size: size, weight: .bold, design: .rounded)
    }

    private func plate(_ snapshot: WidgetSnapshot, _ summary: WidgetSummaryMetric) -> some View {
        WidgetStatusPlate(tone: summary.amount.tone) {
            VStack(alignment: .leading, spacing: 0) {
                if family != .systemSmall, let month = WidgetMonthID.displayName(snapshot.month) {
                    Text(month).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                }
                Text(summary.kind.title).font(.caption.weight(.semibold)).opacity(0.75)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(summary.amount.formatted).font(heroFont).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .widgetAccentable()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    @ViewBuilder private func details(
        _ snapshot: WidgetSnapshot, _ overview: WidgetMonthOverviewSnapshot, _ progress: WidgetMonthProgress?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if family != .systemSmall { Spacer(minLength: 0) }
            spending(overview, progress)
            if usesRows {
                Spacer(minLength: 8)
                rows(overview)
                staleness(snapshot)
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
        .frame(minHeight: WidgetSizeSupport.size(family) == .extraLarge ? 40 : 30)
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
        case .budgeted: "of \(overview.budgeted.formatted)"
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

    @ViewBuilder private func staleness(_ snapshot: WidgetSnapshot) -> some View {
        if !Calendar.autoupdatingCurrent.isDate(snapshot.updatedAt, inSameDayAs: entry.date) {
            Text("Updated \(snapshot.updatedAt, format: .dateTime.month(.abbreviated).day())")
                .font(.caption2).foregroundStyle(palette.secondaryText).padding(.top, 6)
        }
    }
}

private enum WidgetPlateMetrics {
    static let inset: CGFloat = 6
    static let detailVertical: CGFloat = 12
}
