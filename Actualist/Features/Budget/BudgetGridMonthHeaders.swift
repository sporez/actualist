import SwiftUI

struct BudgetGridMonthHeaders: View {
    @Environment(\.actualistDensity) private var density
    private var sizing: BudgetGridDensityMetrics { .init(density: density) }
    let presentation: BudgetGridPresentation
    let metrics: BudgetLayoutMetrics
    let actions: BudgetWorkspaceActions

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Text("Category")
                .font(ActualistTypography.rowTitle(for: density))
                .frame(width: metrics.categoryColumnWidth, alignment: .leading)
                .padding(.bottom, sizing.headerPadding)

            ForEach(presentation.months) { month in
                VStack(spacing: sizing.headerSpacing) {
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
                            Text(month.title).font(ActualistTypography.sectionTitle(for: density))
                            Image(systemName: "ellipsis").font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(month.title), month actions")

                    VStack(spacing: 2) {
                        Text(month.toBudgetText)
                            .font(ActualistTypography.rowTitle(for: density).bold())
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Text("To Budget").font(.caption)
                    }
                    .foregroundStyle(month.toBudgetAmount < 0 ? ActualistTheme.warning : month.toBudgetAmount == 0 ? ActualistTheme.secondaryText : ActualistTheme.positive)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(month.title), To Budget, \(month.toBudgetText)")

                    if let assigned = month.assignedText {
                        Text("Assigned \(assigned)")
                            .font(.caption)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
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
                    if let error = month.error {
                        Text(error).font(.caption).foregroundStyle(ActualistTheme.danger).lineLimit(2)
                    } else if month.snapshot == nil {
                        ProgressView().accessibilityLabel("Loading \(month.title)")
                    }
                    HStack(spacing: 8) {
                        Text("Assigned").frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Available").frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .padding(.top, 4)
                }
                .padding(.horizontal, sizing.cellPadding)
                .padding(.vertical, sizing.headerPadding)
                .frame(width: metrics.monthColumnWidth)
            }
        }
        .foregroundStyle(ActualistTheme.primaryText)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ActualistTheme.separator).frame(height: 1)
        }
    }
}
