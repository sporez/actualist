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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.load(using: appState) }
                    } label: {
                        if viewModel.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading || viewModel.isRefreshing)
                    .accessibilityLabel("Refresh Reports")
                }
            }
            .task { await viewModel.load(using: appState) }
            .refreshable { await viewModel.load(using: appState) }
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
            }

            content
        }
        .padding(16)
        .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct NetWorthReportCard: View {
    let snapshot: ReportsDashboardSnapshot
    let viewModel: ReportsViewModel

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
                    y: .value("Balance", point.value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [ActualistTheme.positive.opacity(0.36), ActualistTheme.positive.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Balance", point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(ActualistTheme.positive)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            .reportChartAxes(viewModel: viewModel, showsDates: true)
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
                    y: .value("Amount", snapshot.cashFlow.income)
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
                    y: .value("Amount", snapshot.cashFlow.expenses)
                )
                .foregroundStyle(ActualistTheme.danger)
                .cornerRadius(4)
                .annotation(position: .top) {
                    Text(viewModel.cashFlowExpenseText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ActualistTheme.danger)
                }
            }
            .reportChartAxes(viewModel: viewModel, showsDates: false)
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
                    AreaMark(x: .value("Day", point.day), y: .value("Current", current))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [ActualistTheme.positive.opacity(0.30), ActualistTheme.positive.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Current", current),
                        series: .value("Series", "Current")
                    )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(ActualistTheme.positive)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }

                LineMark(
                    x: .value("Day", point.day),
                    y: .value("Previous", point.comparison),
                    series: .value("Series", "Previous")
                )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(ActualistTheme.secondaryText.opacity(0.62))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 5]))
            }
            .reportDayComparisonAxes(viewModel: viewModel)
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
                    AreaMark(x: .value("Date", point.date), y: .value("Actual", point.value))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [ActualistTheme.positive.opacity(0.30), ActualistTheme.positive.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Actual", point.value),
                        series: .value("Series", "Actual")
                    )
                        .foregroundStyle(ActualistTheme.positive)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                ForEach(snapshot.budgetOverview.budgetPoints) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Budgeted", point.value),
                        series: .value("Series", "Budgeted")
                    )
                        .foregroundStyle(ActualistTheme.secondaryText.opacity(0.58))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 5]))
                }
            }
            .reportChartAxes(viewModel: viewModel, showsDates: true, showsDayOfMonth: true)
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
                    AreaMark(x: .value("Day", point.day), y: .value("Current", current))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [ActualistTheme.positive.opacity(0.30), ActualistTheme.positive.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Current", current),
                        series: .value("Series", "Current")
                    )
                        .foregroundStyle(ActualistTheme.positive)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                LineMark(
                    x: .value("Day", point.day),
                    y: .value("Average", point.comparison),
                    series: .value("Series", "Average")
                )
                    .foregroundStyle(ActualistTheme.secondaryText.opacity(0.58))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 5]))
            }
            .reportDayComparisonAxes(viewModel: viewModel)
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

private extension ReportValueTone {
    var color: Color {
        switch self {
        case .neutral: ActualistTheme.primaryText
        case .positive: ActualistTheme.positive
        case .warning: ActualistTheme.warning
        case .danger: ActualistTheme.danger
        }
    }
}

private extension View {
    func reportChartAxes(
        viewModel: ReportsViewModel,
        showsDates: Bool,
        showsDayOfMonth: Bool = false
    ) -> some View {
        self
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(ActualistTheme.separator)
                    AxisValueLabel(anchor: .trailing) {
                        if let amount = value.as(Int.self) {
                            Text(viewModel.axisLabel(amount))
                                .font(.caption2)
                                .foregroundStyle(ActualistTheme.secondaryText)
                        }
                    }
                }
            }
            .chartXAxis {
                if showsDates {
                    AxisMarks(values: .automatic(desiredCount: 3)) { value in
                        if showsDayOfMonth {
                            AxisValueLabel(format: .dateTime.day(), anchor: .top)
                                .font(.caption2)
                                .foregroundStyle(ActualistTheme.secondaryText)
                        } else {
                            AxisValueLabel(format: .dateTime.month(.abbreviated), anchor: .top)
                                .font(.caption2)
                                .foregroundStyle(ActualistTheme.secondaryText)
                        }
                    }
                } else {
                    AxisMarks { _ in
                        AxisValueLabel(anchor: .top)
                            .font(.caption2)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
                }
            }
    }

    func reportDayComparisonAxes(viewModel: ReportsViewModel) -> some View {
        self
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(ActualistTheme.separator)
                    AxisValueLabel(anchor: .trailing) {
                        if let amount = value.as(Int.self) {
                            Text(viewModel.axisLabel(amount))
                                .font(.caption2)
                                .foregroundStyle(ActualistTheme.secondaryText)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel(anchor: .top) {
                        if let day = value.as(Int.self) {
                            Text("\(day)")
                                .font(.caption2)
                                .foregroundStyle(ActualistTheme.secondaryText)
                        }
                    }
                }
            }
    }
}
