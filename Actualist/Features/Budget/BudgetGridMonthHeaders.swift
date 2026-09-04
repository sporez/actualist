import SwiftUI

struct BudgetGridMonthHeaders: View {
    let presentation: BudgetGridPresentation
    let metrics: BudgetLayoutMetrics
    let actions: BudgetWorkspaceActions

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Text("Category")
                .font(.subheadline.weight(.semibold))
                .frame(width: metrics.categoryColumnWidth, alignment: .leading)
                .padding(.bottom, 10)

            ForEach(presentation.months) { month in
                VStack(spacing: 8) {
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
                            Text(month.title).font(.headline)
                            Image(systemName: "ellipsis").font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(month.title), month actions")

                    VStack(spacing: 2) {
                        Text(month.toBudgetText)
                            .font(metrics.visibleMonthCount == 1 ? .title2.weight(.bold) : .headline)
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
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .frame(width: metrics.monthColumnWidth)
            }
        }
        .foregroundStyle(ActualistTheme.primaryText)
        .background(ActualistTheme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ActualistTheme.separator).frame(height: 1)
        }
    }
}
