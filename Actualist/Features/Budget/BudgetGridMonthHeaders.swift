import SwiftUI

struct BudgetGridMonthHeaders: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    private var sizing: BudgetGridDensityMetrics { .init(density: density) }
    let presentation: BudgetGridPresentation
    let metrics: BudgetLayoutMetrics
    let actions: BudgetWorkspaceActions
    /// Scrolling can hide the navigation title, which is the only other place
    /// a single month is named.
    let showsMonthWhileScrolled: Bool

    var body: some View {
        VStack(spacing: 0) {
            if presentation.months.count == 1, let month = presentation.months.first {
                singleMonthHeader(month)
                    .frame(width: metrics.tableWidth)
            } else {
                monthColumnHeaders
            }
            columnLabels
        }
        .foregroundStyle(ActualistTheme.primaryText)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ActualistTheme.separator).frame(height: 1)
        }
    }

    /// The header stays pinned, so one month gets a single line: the navigation
    /// title already names the month, and short windows need the height for rows.
    private func singleMonthHeader(_ month: BudgetGridPresentation.Month) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                inlineSummary(month)
                Spacer(minLength: 0)
                alerts(month)
                status(month)
                monthMenu(month, showsTitle: showsMonthWhileScrolled)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    inlineSummary(month)
                    Spacer(minLength: 0)
                    monthMenu(month, showsTitle: showsMonthWhileScrolled)
                }
                HStack(spacing: 14) {
                    alerts(month)
                    status(month)
                }
            }
        }
        .padding(.leading, BudgetLayout.rowHorizontalPadding)
        .padding(.trailing, sizing.cellPadding)
        .padding(.vertical, sizing.headerPadding / 2)
    }

    private func inlineSummary(_ month: BudgetGridPresentation.Month) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            summaryButton(month, isInline: true)
            detailTexts(month)
        }
    }

    private var monthColumnHeaders: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Color.clear.frame(width: metrics.categoryColumnWidth, height: 0)

            ForEach(presentation.months) { month in
                VStack(spacing: sizing.headerSpacing) {
                    monthMenu(month, showsTitle: true)
                    ViewThatFits(in: .horizontal) {
                        summaryButton(month, isInline: true)
                        summaryButton(month, isInline: false)
                    }
                    if month.savings != nil || month.assignedText != nil {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { detailTexts(month) }
                            VStack(spacing: sizing.headerSpacing) { detailTexts(month) }
                        }
                    }
                    if !month.alerts.isEmpty {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { alerts(month) }
                            VStack(spacing: 0) { alerts(month) }
                        }
                    }
                    status(month)
                }
                .padding(.horizontal, sizing.cellPadding)
                .padding(.vertical, sizing.headerPadding)
                .frame(width: metrics.monthColumnWidth)
                .transition(.opacity)
            }
        }
    }

    private var columnLabels: some View {
        HStack(spacing: 0) {
            Text("Category")
                .padding(.leading, BudgetLayout.rowHorizontalPadding)
                .frame(width: metrics.categoryColumnWidth, alignment: .leading)

            ForEach(presentation.months) { month in
                HStack(spacing: 8) {
                    columnLabel(month.semantics.budgetedLabel)
                    columnLabel(month.semantics.secondValueLabel)
                }
                .padding(.horizontal, sizing.cellPadding)
                .frame(width: metrics.monthColumnWidth)
                .transition(.opacity)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(ActualistTheme.secondaryText)
        .padding(.vertical, 6)
    }

    private func columnLabel(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func monthMenu(_ month: BudgetGridPresentation.Month, showsTitle: Bool) -> some View {
        Menu {
            Button("Notes", systemImage: "note.text") { actions.openMonthNote(month.id) }
            if BudgetTemplateActionAvailability.hasMonthActions(in: month.snapshot?.month, isTrackingBudget: month.snapshot?.isTrackingBudget ?? false) {
                Button("Apply Template", systemImage: "sparkles") {
                    actions.requestMonthTemplate(.fillEmpty, month: month.id)
                }
                Button("Apply Template Overwrite", systemImage: "sparkles.square.filled.on.square") {
                    actions.requestMonthTemplate(.overwrite, month: month.id)
                }
            }
        } label: {
            HStack(spacing: 5) {
                if showsTitle {
                    Text(month.title).font(ActualistTypography.sectionTitle(for: density))
                }
                Image(systemName: "ellipsis").font(.caption)
            }
            .frame(minWidth: 44, maxWidth: presentation.months.count > 1 ? .infinity : nil, minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(month.title), month actions")
    }

    @ViewBuilder
    private func summaryButton(_ month: BudgetGridPresentation.Month, isInline: Bool) -> some View {
        if actions.canOpenHold(month.id, using: appState) {
            Button {
                actions.openHold(month.id, using: appState)
            } label: {
                summaryLabel(month, isInline: isInline)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("budget-hold-open-\(month.id)")
        } else {
            summaryLabel(month, isInline: isInline)
        }
    }

    @ViewBuilder
    private func detailTexts(_ month: BudgetGridPresentation.Month) -> some View {
        if let savings = month.savings {
            Text(savings.incomeText).font(.caption)
            Text(savings.expensesText).font(.caption)
        }
        if let assigned = month.assignedText {
            Text("Budgeted \(assigned)")
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
    }

    private func alerts(_ month: BudgetGridPresentation.Month) -> some View {
        ForEach(month.alerts) { alert in
            Button { actions.openAlert(alert, month: month.id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text("\(alert.count ?? 0) \(alert.kind == .overspending ? "Overspent" : "Uncategorized")")
                        .lineLimit(2)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(alert.kind == .overspending ? ActualistTheme.danger : ActualistTheme.warning)
                .frame(minHeight: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(month.title), \(alert.count ?? 0) \(alert.title), \(alert.actionTitle ?? "Open")")
        }
    }

    @ViewBuilder
    private func status(_ month: BudgetGridPresentation.Month) -> some View {
        if let error = month.error {
            Text(error).font(.caption).foregroundStyle(ActualistTheme.danger).lineLimit(2)
        } else if month.snapshot == nil {
            ProgressView().accessibilityLabel("Loading \(month.title)")
        }
    }

    private func summaryLabel(_ month: BudgetGridPresentation.Month, isInline: Bool) -> some View {
        let summary = month.summary
        return Group {
            if isInline {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    summaryText(summary)
                }
            } else {
                VStack(spacing: 2) {
                    summaryText(summary)
                }
            }
        }
        .foregroundStyle(summary.amount < 0 ? (summary.isTracking ? ActualistTheme.danger : ActualistTheme.warning) : summary.amount == 0 ? ActualistTheme.secondaryText : ActualistTheme.positive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(month.title), \(summary.title), \(summary.text)")
    }

    @ViewBuilder
    private func summaryText(_ summary: BudgetGridPresentation.Summary) -> some View {
        Text(summary.text)
            .font(ActualistTypography.rowTitle(for: density).bold())
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        Text(summary.title).font(.caption)
    }
}
