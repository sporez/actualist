import Charts
import SwiftUI

struct ReportsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @State private var viewModel = ReportsViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if let errorMessage = viewModel.errorMessage {
                        ReportsErrorBanner(message: errorMessage)
                    }

                    if let snapshot = viewModel.displaySnapshot, snapshot.hasData {
                        ReportsDashboardContent(
                            snapshot: snapshot,
                            viewModel: viewModel,
                            reportCardOrder: appState.settings.reportCardOrder
                        )
                    } else if viewModel.isLoading {
                        ReportsLoadingView()
                    } else {
                        ContentUnavailableView(
                            "No Report Data",
                            systemImage: "chart.xyaxis.line",
                            description: Text("Transactions will appear here after this budget has local history.")
                        )
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 360)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(ActualistTheme.background)
            .navigationTitle("Reports")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ReportCardKind.self) { reportCard in
                ReportExplorerView(reportCard: reportCard)
            }
            .task { await viewModel.load(using: appState) }
            .refreshable { await viewModel.refresh(using: appState) }
            .onChange(of: appState.localDataRevision) {
                Task { await viewModel.load(using: appState) }
            }
            .onChange(of: appState.selectedTab) { _, tab in
                if tab == .reports, viewModel.displaySnapshot != nil {
                    Task { await viewModel.load(using: appState) }
                }
            }
            .onChange(of: appState.settings.randomizedDisplayValuesEnabled) { _, enabled in
                viewModel.updatePrivacyMode(enabled)
            }
            .environment(\.calendar, ReportCalendar.gregorianUTC)
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0) ?? .gmt)
        }
    }
}

struct ReportsDashboardContent: View {
    let snapshot: ReportsDashboardSnapshot
    let viewModel: ReportsViewModel
    let reportCardOrder: [ReportCardKind]

    init(
        snapshot: ReportsDashboardSnapshot,
        viewModel: ReportsViewModel,
        reportCardOrder: [ReportCardKind] = ReportCardOrderPreference.defaultOrder
    ) {
        self.snapshot = snapshot
        self.viewModel = viewModel
        self.reportCardOrder = ReportCardOrderPreference.normalized(reportCardOrder)
    }

    var body: some View {
        VStack(spacing: 14) {
            ForEach(reportCardOrder) { reportCard in
                NavigationLink(value: reportCard) {
                    switch reportCard {
                    case .netWorth:
                        NetWorthReportCard(snapshot: snapshot, viewModel: viewModel)
                    case .cashFlow:
                        CashFlowReportCard(snapshot: snapshot, viewModel: viewModel)
                    case .monthComparison:
                        MonthComparisonReportCard(snapshot: snapshot, viewModel: viewModel)
                    case .budgetOverview:
                        BudgetOverviewReportCard(snapshot: snapshot, viewModel: viewModel)
                    case .threeMonthAverage:
                        ThreeMonthAverageReportCard(snapshot: snapshot, viewModel: viewModel)
                    case .transactionCalendar:
                        TransactionCalendarReportCard(snapshot: snapshot, viewModel: viewModel)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens report details")
            }
        }
    }
}

private struct ReportsLoadingView: View {
    @Environment(\.actualistDensity) private var density

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Building reports from this budget")
                .font(ActualistTypography.rowTitle(for: density))
            Text("This uses the local transaction history and works offline after the first load.")
                .font(ActualistTypography.body(for: density))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(ActualistTheme.secondaryText)
        .frame(maxWidth: .infinity, minHeight: 360)
        .padding(24)
    }
}

private struct ReportsErrorBanner: View {
    @Environment(\.actualistDensity) private var density
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(ActualistTypography.body(for: density))
            Spacer(minLength: 0)
        }
        .foregroundStyle(ActualistTheme.danger)
        .padding(14)
        .background(ActualistTheme.danger.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ReportCard<Content: View>: View {
    @Environment(\.actualistDensity) private var density
    let title: String
    let subtitle: String
    let headline: String?
    let tone: ReportValueTone
    let content: Content

    init(
        title: String,
        subtitle: String,
        headline: String?,
        tone: ReportValueTone,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.headline = headline
        self.tone = tone
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(ActualistTypography.sectionTitle(for: density))
                        .foregroundStyle(ActualistTheme.primaryText)
                    Text(subtitle)
                        .font(ActualistTypography.rowLabel(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                Spacer(minLength: 8)
                if let headline {
                    Text(headline)
                        .font(ActualistTypography.rowValue(for: density).weight(.bold))
                        .foregroundStyle(tone.color)
                        .multilineTextAlignment(.trailing)
                        .minimumScaleFactor(0.72)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .accessibilityHidden(true)
            }

            content
        }
        .padding(16)
        .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct NetWorthReportCard: View {
    let snapshot: ReportsDashboardSnapshot
    let viewModel: ReportsViewModel

    private var yDomain: ClosedRange<Int> {
        let values = snapshot.netWorth.points.map(\.value)
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 0
        return minimum == maximum ? (minimum - 1)...(maximum + 1) : minimum...maximum
    }

    var body: some View {
        ReportCard(
            title: "Net Worth",
            subtitle: viewModel.netWorthSubtitle,
            headline: viewModel.netWorthHeadline,
            tone: .neutral
        ) {
            HStack {
                Spacer()
                Text(viewModel.netWorthChangeText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(viewModel.netWorthTone.color)
            }
            Chart(snapshot.netWorth.points) { point in
                AreaMark(
                    x: .value("Date", point.date),
                    yStart: .value("Visible Baseline", yDomain.lowerBound),
                    yEnd: .value("Balance", point.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(ActualistTheme.positive.opacity(0.20))

                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Balance", point.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(ActualistTheme.positive)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .actualCompactReportChartStyle()
            .chartYScale(domain: yDomain)
            .frame(height: 190)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(viewModel.netWorthAccessibility)
        }
    }
}

private struct CashFlowReportCard: View {
    let snapshot: ReportsDashboardSnapshot
    let viewModel: ReportsViewModel

    var body: some View {
        ReportCard(
            title: "Cash Flow",
            subtitle: viewModel.cashFlowSubtitle,
            headline: viewModel.cashFlowHeadline,
            tone: viewModel.cashFlowTone
        ) {
            Chart {
                BarMark(
                    x: .value("Type", "Income"),
                    y: .value("Amount", snapshot.cashFlow.income),
                    width: .fixed(14)
                )
                .foregroundStyle(ActualistTheme.positive)
                .cornerRadius(4)
                .annotation(position: .top) {
                    Text(viewModel.cashFlowIncomeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ActualistTheme.positive)
                }

                BarMark(
                    x: .value("Type", "Expenses"),
                    y: .value("Amount", snapshot.cashFlow.expenses),
                    width: .fixed(14)
                )
                .foregroundStyle(ActualistTheme.danger)
                .cornerRadius(4)
                .annotation(position: .top) {
                    Text(viewModel.cashFlowExpenseText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ActualistTheme.danger)
                }
            }
            .actualCompactReportChartStyle()
            .frame(height: 180)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(viewModel.cashFlowAccessibility)

            if let uncategorized = viewModel.uncategorizedText {
                Label(uncategorized, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.warning)
            }
        }
    }
}

private struct MonthComparisonReportCard: View {
    let snapshot: ReportsDashboardSnapshot
    let viewModel: ReportsViewModel

    var body: some View {
        ReportCard(
            title: "This Month",
            subtitle: viewModel.monthComparisonSubtitle,
            headline: viewModel.monthComparisonHeadline,
            tone: viewModel.monthComparisonTone
        ) {
            Chart(snapshot.monthComparison.points) { point in
                if let current = point.current {
                    ReportAreaLineSeries(xLabel: "Day", x: point.day, name: "Current", y: current, style: .current)
                }
                ReportAreaLineSeries(
                    xLabel: "Day",
                    x: point.day,
                    name: "Previous",
                    y: point.comparison,
                    style: .reference(lineOpacity: 0.62)
                )
            }
            .actualCompactReportChartStyle()
            .frame(height: 190)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(viewModel.monthComparisonAccessibility)
        }
    }
}

private struct BudgetOverviewReportCard: View {
    let snapshot: ReportsDashboardSnapshot
    let viewModel: ReportsViewModel

    var body: some View {
        ReportCard(
            title: "Budget Overview",
            subtitle: viewModel.budgetOverviewSubtitle,
            headline: viewModel.budgetOverviewHeadline,
            tone: viewModel.budgetOverviewTone
        ) {
            Chart {
                ForEach(snapshot.budgetOverview.actualPoints) { point in
                    ReportAreaLineSeries(xLabel: "Date", x: point.date, name: "Actual", y: point.value, style: .current)
                }
                ForEach(snapshot.budgetOverview.budgetPoints) { point in
                    ReportAreaLineSeries(
                        xLabel: "Date",
                        x: point.date,
                        name: "Budgeted",
                        y: point.value,
                        style: .reference(lineOpacity: 0.58)
                    )
                }
            }
            .actualCompactReportChartStyle()
            .frame(height: 190)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(viewModel.budgetOverviewAccessibility)
        }
    }
}

private struct ThreeMonthAverageReportCard: View {
    let snapshot: ReportsDashboardSnapshot
    let viewModel: ReportsViewModel

    var body: some View {
        ReportCard(
            title: "3-Month Average",
            subtitle: viewModel.threeMonthAverageSubtitle,
            headline: viewModel.threeMonthAverageHeadline,
            tone: viewModel.threeMonthAverageTone
        ) {
            Chart(snapshot.threeMonthAverage.points) { point in
                if let current = point.current {
                    ReportAreaLineSeries(xLabel: "Day", x: point.day, name: "Current", y: current, style: .current)
                }
                ReportAreaLineSeries(
                    xLabel: "Day",
                    x: point.day,
                    name: "Average",
                    y: point.comparison,
                    style: .reference(lineOpacity: 0.58)
                )
            }
            .actualCompactReportChartStyle()
            .frame(height: 190)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(viewModel.threeMonthAverageAccessibility)
        }
    }
}

private struct TransactionCalendarReportCard: View {
    @Environment(\.actualistDensity) private var density
    let snapshot: ReportsDashboardSnapshot
    let viewModel: ReportsViewModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        ReportCard(
            title: "Transaction Calendar",
            subtitle: viewModel.calendarRangeTitle,
            headline: nil,
            tone: .neutral
        ) {
            ForEach(snapshot.transactionCalendar) { month in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(ReportCalendar.monthTitle(month.month))
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.primaryText)
                        Spacer(minLength: 6)
                        Label(viewModel.calendarMonthIncome(month), systemImage: "arrow.up")
                            .foregroundStyle(ActualistTheme.positive)
                        Label(viewModel.calendarMonthExpenses(month), systemImage: "arrow.down")
                            .foregroundStyle(ActualistTheme.danger)
                    }
                    .font(.caption2.weight(.semibold))
                    .minimumScaleFactor(0.68)

                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(Array(viewModel.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                            Text(symbol)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(ActualistTheme.secondaryText)
                                .frame(maxWidth: .infinity)
                        }

                        ForEach(
                            (0..<month.leadingBlankCount).map { "\(month.id)-blank-\($0)" },
                            id: \.self
                        ) { _ in
                            Color.clear.frame(height: 34)
                        }

                        ForEach(month.days) { day in
                            TransactionCalendarCell(day: day, viewModel: viewModel)
                        }
                    }
                }
                .padding(.top, month.id == snapshot.transactionCalendar.first?.id ? 0 : 8)
                .accessibilityElement(children: .contain)
            }
        }
    }
}

private struct TransactionCalendarCell: View {
    let day: TransactionCalendarDay
    let viewModel: ReportsViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(ActualistTheme.elevatedSurface)

            VStack(spacing: 1) {
                Rectangle()
                    .fill(ActualistTheme.positive.opacity(viewModel.calendarIntensity(day.income)))
                Rectangle()
                    .fill(ActualistTheme.danger.opacity(viewModel.calendarIntensity(day.expenses)))
            }
            .frame(height: 8)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5))

            Text("\(day.day)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(ActualistTheme.primaryText)
                .padding(.bottom, 11)
        }
        .frame(height: 34)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(viewModel.calendarDayAccessibility(day))
    }
}

extension ReportValueTone {
    var color: Color {
        switch self {
        case .neutral: ActualistTheme.primaryText
        case .positive: ActualistTheme.positive
        case .warning: ActualistTheme.warning
        case .danger: ActualistTheme.danger
        }
    }
}

/// One filled line series: the solid green "current" series or the dashed
/// gray reference series shared by the three comparison cards.
private struct ReportAreaLineSeries<X: Plottable>: ChartContent {
    enum Style {
        case current
        case reference(lineOpacity: Double)
    }

    let xLabel: String
    let x: X
    let name: String
    let y: Int
    let style: Style

    private var areaColor: Color {
        switch style {
        case .current: ActualistTheme.positive.opacity(0.20)
        case .reference: ActualistTheme.secondaryText.opacity(0.20)
        }
    }

    private var lineColor: Color {
        switch style {
        case .current: ActualistTheme.positive
        case .reference(let opacity): ActualistTheme.secondaryText.opacity(opacity)
        }
    }

    private var lineStyle: StrokeStyle {
        switch style {
        case .current: StrokeStyle(lineWidth: 3, lineCap: .round)
        case .reference: StrokeStyle(lineWidth: 3, dash: [10, 10])
        }
    }

    var body: some ChartContent {
        AreaMark(
            x: .value(xLabel, x),
            y: .value(name, y),
            series: .value("Series", name),
            stacking: .unstacked
        )
        .foregroundStyle(areaColor)
        LineMark(
            x: .value(xLabel, x),
            y: .value(name, y),
            series: .value("Series", name)
        )
        .foregroundStyle(lineColor)
        .lineStyle(lineStyle)
    }
}

private extension View {
    func actualCompactReportChartStyle() -> some View {
        self
            .chartLegend(.hidden)
            .chartYAxis(.hidden)
            .chartXAxis(.hidden)
    }
}
