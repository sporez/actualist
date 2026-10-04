import Charts
import SwiftUI

struct ReportExplorerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewModel: ReportExplorerViewModel
    @State private var isCustomRangePresented = false
    @State private var isFilterPresented = false

    init(reportCard: ReportCardKind) {
        _viewModel = State(initialValue: ReportExplorerViewModel(reportCard: reportCard))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ReportExplorerRangeSummary(viewModel: viewModel)

                if let message = viewModel.invalidRangeMessage ?? viewModel.errorMessage {
                    reportExplorerMessage(message, tone: .danger)
                }

                if let snapshot = viewModel.displaySnapshot, snapshot.hasData {
                    ReportExplorerTotalsView(viewModel: viewModel)
                    if let request = viewModel.drilldownRequest {
                        NavigationLink {
                            ReportTransactionDrilldownView(
                                title: "\(viewModel.title) Transactions",
                                request: request
                            )
                        } label: {
                            let layout = dynamicTypeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
                            layout {
                                Image(systemName: "list.bullet.rectangle")
                                    .accessibilityHidden(true)
                                Text("View Contributing Transactions")
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(
                                maxWidth: .infinity,
                                alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center
                            )
                            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 6 : 0)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.roundedRectangle(radius: 18))
                        .accessibilityIdentifier("report-drilldown-button")
                    }
                    ReportExplorerChart(snapshot: snapshot, viewModel: viewModel)
                } else if viewModel.isLoading {
                    ProgressView("Loading report")
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 280)
                } else if viewModel.invalidRangeMessage == nil, viewModel.errorMessage == nil {
                    ContentUnavailableView(
                        "No Activity in This Range",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Choose another date range to explore this report.")
                    )
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 280)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(ActualistTheme.background)
        .navigationTitle(viewModel.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Principal placement keeps every report explorer title centered;
            // long titles next to the trailing glass capsule otherwise fall
            // back to leading alignment (seen on "Budget Overview").
            ToolbarItem(placement: .principal) {
                Text(viewModel.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isFilterPresented = true
                } label: {
                    Image(systemName: viewModel.activeFilterCount == 0
                        ? "line.3.horizontal.decrease"
                        : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("Report filters")
                .accessibilityIdentifier("report-filter-button")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if viewModel.usesComparisonMonthSelection {
                    Menu {
                        Button {
                            viewModel.selectPreviousComparisonMonth()
                        } label: {
                            Label("Previous Month", systemImage: "chevron.left")
                        }
                        Button {
                            viewModel.selectNextComparisonMonth()
                        } label: {
                            Label("Next Month", systemImage: "chevron.right")
                        }
                        .disabled(!viewModel.canSelectNextComparisonMonth)
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Comparison month")
                } else {
                    Menu {
                        ForEach(ReportExplorerRangePreset.allCases.filter { $0 != .custom }, id: \.self) { preset in
                            Button {
                                viewModel.selectPreset(preset)
                            } label: {
                                if preset == viewModel.selectedPreset {
                                    Label(preset.title, systemImage: "checkmark")
                                } else {
                                    Text(preset.title)
                                }
                            }
                        }
                        Divider()
                        Button("Custom Range…") {
                            isCustomRangePresented = true
                        }
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Report date range")
                }
            }
            if viewModel.errorMessage != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.retry()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Retry report")
                }
            }
        }
        .sheet(isPresented: $isCustomRangePresented) {
            ReportCustomRangeSheet(
                start: viewModel.customStartDate,
                end: viewModel.customEndDate,
                interval: viewModel.query.interval
            ) { start, end in
                viewModel.selectCustomRange(start: start, end: end)
            }
        }
        .sheet(isPresented: $isFilterPresented) {
            ReportExplorerFilterView(
                metric: viewModel.query.metric,
                filters: viewModel.filters,
                catalog: viewModel.filterCatalog,
                onApply: { viewModel.applyFilters($0) }
            )
        }
        .task(id: loadIdentity) {
            await viewModel.load(using: appState)
        }
        .onChange(of: appState.localDataRevision) {
            viewModel.reload()
        }
        .onChange(of: appState.settings.randomizedDisplayValuesEnabled) { _, enabled in
            viewModel.updatePrivacyMode(enabled)
        }
        .environment(\.calendar, ReportCalendar.gregorianUTC)
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0) ?? .gmt)
    }

    private var loadIdentity: ReportExplorerLoadIdentity {
        ReportExplorerLoadIdentity(
            requestID: viewModel.requestIdentity,
            budgetID: appState.settings.selectedBudgetID,
            sessionGeneration: appState.localFirstStore.budgetSessionGeneration
        )
    }

    private func reportExplorerMessage(_ message: String, tone: ReportValueTone) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(ActualistTypography.body(for: density))
            Spacer(minLength: 0)
        }
        .foregroundStyle(tone.color)
        .padding(14)
        .background(tone.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ReportExplorerRangeSummary: View {
    @Environment(\.actualistDensity) private var density
    let viewModel: ReportExplorerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.rangeTitle)
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.primaryText)
                    Text(viewModel.rangeSelectionTitle)
                        .font(ActualistTypography.rowLabel(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                Spacer(minLength: 8)
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing report")
                }
            }

            Picker("Interval", selection: intervalBinding) {
                ForEach(ReportInterval.allCases, id: \.self) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var intervalBinding: Binding<ReportInterval> {
        Binding(
            get: { viewModel.query.interval },
            set: { viewModel.selectInterval($0) }
        )
    }
}

private struct ReportExplorerTotalsView: View {
    @Environment(\.actualistDensity) private var density
    let viewModel: ReportExplorerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.primaryTotalLabel)
                .font(ActualistTypography.rowLabel(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
            Text(viewModel.primaryTotalText)
                .font(ActualistTypography.workScreenAmount(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .minimumScaleFactor(0.72)

            if !viewModel.secondaryTotals.isEmpty {
                Divider()
                HStack(spacing: 18) {
                    ForEach(Array(viewModel.secondaryTotals.enumerated()), id: \.offset) { _, total in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(total.label)
                                .font(ActualistTypography.rowLabel(for: density))
                                .foregroundStyle(ActualistTheme.secondaryText)
                            Text(total.value)
                                .font(ActualistTypography.rowValue(for: density))
                                .foregroundStyle(total.tone.color)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ReportExplorerChart: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let snapshot: ReportExplorerSnapshot
    let viewModel: ReportExplorerViewModel

    var body: some View {
        Chart {
            ForEach(snapshot.points) { point in
                switch snapshot.query.metric {
                case .netWorth:
                    LineMark(
                        x: .value("Period", point.period.date),
                        y: .value("Balance", point.endingBalance)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(ActualistTheme.positive)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    PointMark(
                        x: .value("Period", point.period.date),
                        y: .value("Balance", point.endingBalance)
                    )
                    .foregroundStyle(ActualistTheme.positive)
                case .cashFlow:
                    BarMark(
                        x: .value("Period", point.period.date),
                        y: .value("Amount", point.income)
                    )
                    .position(by: .value("Type", "Income"))
                    .foregroundStyle(ActualistTheme.positive)
                    .cornerRadius(3)
                    BarMark(
                        x: .value("Period", point.period.date),
                        y: .value("Amount", point.expenses)
                    )
                    .position(by: .value("Type", "Expenses"))
                    .foregroundStyle(ActualistTheme.danger)
                    .cornerRadius(3)
                case .spending:
                    BarMark(
                        x: .value("Period", point.period.date),
                        y: .value("Spending", point.expenses)
                    )
                    .foregroundStyle(ActualistTheme.danger)
                    .cornerRadius(3)
                case .budgetOverview:
                    LineMark(
                        x: .value("Period", point.period.date),
                        y: .value("Spending", point.expenses),
                        series: .value("Series", "Spending")
                    )
                    .foregroundStyle(ActualistTheme.danger)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    LineMark(
                        x: .value("Period", point.period.date),
                        y: .value("Budgeted", point.budgeted),
                        series: .value("Series", "Budgeted")
                    )
                    .foregroundStyle(ActualistTheme.warning)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
                case .spendingAverage:
                    LineMark(
                        x: .value("Period", point.period.date),
                        y: .value("Spending", point.expenses),
                        series: .value("Series", "Spending")
                    )
                    .foregroundStyle(ActualistTheme.danger)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    LineMark(
                        x: .value("Period", point.period.date),
                        y: .value("Average", point.comparison),
                        series: .value("Series", "Average")
                    )
                    .foregroundStyle(ActualistTheme.warning)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
                }
            }
        }
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(
                snapshot.points.count, dynamicTypeSize.isAccessibilitySize ? 1 : 4
            ))) {
                AxisGridLine().foregroundStyle(ActualistTheme.secondaryText.opacity(0.16))
                AxisValueLabel(format: Date.FormatStyle(
                    calendar: ReportCalendar.gregorianUTC,
                    timeZone: .gmt
                ).month(.abbreviated).day())
                    .font(.caption2)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
        }
        .chartYAxis {
            AxisMarks(
                position: .leading,
                values: .automatic(desiredCount: dynamicTypeSize.isAccessibilitySize ? 3 : 5)
            ) { value in
                AxisGridLine().foregroundStyle(ActualistTheme.secondaryText.opacity(0.16))
                AxisValueLabel {
                    if let amount = value.as(Int.self) {
                        Text(viewModel.formatted(amount))
                    }
                }
                .font(.caption2)
                .foregroundStyle(ActualistTheme.secondaryText)
            }
        }
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 360 : 280)
        .padding(16)
        .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(viewModel.title), \(viewModel.rangeTitle)")
        .accessibilityIdentifier("report-explorer-chart")
    }
}

private struct ReportExplorerLoadIdentity: Hashable {
    let requestID: UUID
    let budgetID: String?
    let sessionGeneration: Int
}

private struct ReportCustomRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    let interval: ReportInterval
    let onApply: (Date, Date) -> Void

    init(start: Date, end: Date, interval: ReportInterval, onApply: @escaping (Date, Date) -> Void) {
        _start = State(initialValue: start)
        _end = State(initialValue: end)
        self.interval = interval
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ReviewSheetContent {
                ReviewSheetHeader(title: "Choose the date range")
                VStack(spacing: 8) {
                    DatePicker(
                        "Start",
                        selection: $start,
                        in: ReportExplorerRangeLimits.earliestStart(forEnd: end, interval: interval)...end,
                        displayedComponents: .date
                    )
                        .accessibilityIdentifier("report-custom-range-start")
                    ActualistTheme.separator.frame(height: 1)
                    DatePicker(
                        "End",
                        selection: $end,
                        in: start...ReportExplorerRangeLimits.latestEnd(forStart: start, interval: interval),
                        displayedComponents: .date
                    )
                        .accessibilityIdentifier("report-custom-range-end")
                }
                .font(.body)
                .actualistReviewCard(padding: 14)
            }
            .toolbar(.hidden, for: .navigationBar)
            .reviewSheetBottomBar {
                Button(role: .cancel) { dismiss() } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 32)
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("report-custom-range-cancel")

                Button {
                    onApply(start, end)
                    dismiss()
                } label: {
                    Text("Apply")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.glassProminent)
                .tint(ActualistTheme.accent)
                .accessibilityIdentifier("report-custom-range-apply")
            }
        }
        .frame(idealWidth: 520)
        .presentationDetents([.medium])
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .accessibilityIdentifier("report-custom-range-sheet")
        .presentationBackground(ActualistTheme.background)
        .environment(\.calendar, ReportCalendar.gregorianUTC)
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0) ?? .gmt)
    }
}
