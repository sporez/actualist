import Charts
import SwiftUI

struct ReportExplorerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @State private var viewModel: ReportExplorerViewModel
    @State private var isCustomRangePresented = false

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
            ToolbarItem(placement: .topBarTrailing) {
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
                end: viewModel.customEndDate
            ) { start, end in
                viewModel.selectCustomRange(start: start, end: end)
            }
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
                    Text(viewModel.selectedPreset.title)
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
                case .spending, .spendingAverage:
                    BarMark(
                        x: .value("Period", point.period.date),
                        y: .value("Spending", point.expenses)
                    )
                    .foregroundStyle(ActualistTheme.danger)
                    .cornerRadius(3)
                case .budgetOverview:
                    BarMark(
                        x: .value("Period", point.period.date),
                        y: .value("Spending", point.expenses)
                    )
                    .foregroundStyle(ActualistTheme.danger)
                    .cornerRadius(3)
                    LineMark(
                        x: .value("Period", point.period.date),
                        y: .value("Budgeted", point.budgeted)
                    )
                    .foregroundStyle(ActualistTheme.warning)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
                }
            }
            if snapshot.query.metric == .spendingAverage {
                RuleMark(y: .value("Average", snapshot.totals.averageSpending))
                    .foregroundStyle(ActualistTheme.warning)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
        }
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(snapshot.points.count, 6))) {
                AxisGridLine().foregroundStyle(ActualistTheme.secondaryText.opacity(0.16))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(ActualistTheme.secondaryText.opacity(0.16))
                AxisValueLabel {
                    if let amount = value.as(Int.self) {
                        Text(viewModel.formatted(amount))
                    }
                }
                .foregroundStyle(ActualistTheme.secondaryText)
            }
        }
        .frame(height: 280)
        .padding(16)
        .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(viewModel.title), \(viewModel.rangeTitle)")
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
    let onApply: (Date, Date) -> Void

    init(start: Date, end: Date, onApply: @escaping (Date, Date) -> Void) {
        _start = State(initialValue: start)
        _end = State(initialValue: end)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Start", selection: $start, displayedComponents: .date)
                DatePicker("End", selection: $end, displayedComponents: .date)
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .navigationTitle("Custom Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(start, end)
                        dismiss()
                    }
                }
            }
        }
        .frame(idealWidth: 520)
        .presentationDetents([.medium])
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .environment(\.calendar, ReportCalendar.gregorianUTC)
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0) ?? .gmt)
    }
}
