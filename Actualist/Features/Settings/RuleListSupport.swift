import SwiftUI

/// Row content shared by the payee and budget-wide rules lists: stage caption,
/// summary, and the lock note for read-only rules.
struct RuleRowLabel: View {
    let rule: ManagedRule
    let options: RuleEditorOptions?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(rule.isScheduleOwned ? "Schedule · View Only" : rule.draft?.stage.displayName ?? "View Only")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ActualistTheme.secondaryText)
            Text(rule.summary(options: options))
                .foregroundStyle(ActualistTheme.primaryText)
                .multilineTextAlignment(.leading)
            if !rule.isEditable {
                Label(
                    rule.isScheduleOwned
                        ? "Belongs to a schedule"
                        : "Cannot be edited in this version",
                    systemImage: "lock.fill"
                )
                .font(.caption2)
                .foregroundStyle(ActualistTheme.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct RulesListErrorText: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(ActualistTheme.danger)
            .settingsRowChrome()
    }
}

private struct RuleEditorSheetModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Binding var target: RuleEditorTarget?
    let viewModel: RulesListViewModel

    func body(content: Content) -> some View {
        content.sheet(item: $target) { target in
            RuleEditorView(
                target: target,
                isSubmitting: viewModel.isSubmitting,
                errorMessage: viewModel.errorMessage
            ) { draft in
                await viewModel.save(
                    ruleID: target.rule?.id,
                    draft: draft,
                    using: appState
                )
            }
        }
    }
}

private struct RuleDeleteConfirmationModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Binding var pendingRule: ManagedRule?
    let rule: ManagedRule
    let viewModel: RulesListViewModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete Rule?",
            isPresented: $pendingRule.isPresented(matching: rule.id),
            titleVisibility: .visible
        ) {
            Button("Delete Rule", role: .destructive) {
                Task { _ = await viewModel.delete(ruleID: rule.id, using: appState) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This rule will stop applying to new transactions.")
        }
    }
}

extension View {
    func ruleEditorSheet(target: Binding<RuleEditorTarget?>, viewModel: RulesListViewModel) -> some View {
        modifier(RuleEditorSheetModifier(target: target, viewModel: viewModel))
    }

    func ruleDeleteConfirmation(
        pendingRule: Binding<ManagedRule?>,
        rule: ManagedRule,
        viewModel: RulesListViewModel
    ) -> some View {
        modifier(RuleDeleteConfirmationModifier(pendingRule: pendingRule, rule: rule, viewModel: viewModel))
    }
}
