import SwiftUI

/// Row content shared by the payee and budget-wide rules lists: stage caption,
/// summary, and the lock note for read-only rules.
struct RuleRowLabel: View {
    let rule: ManagedRule
    let options: RuleEditorOptions?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(rule.isScheduleOwned ? "Schedule · Read-only" : rule.draft?.stage.displayName ?? "Read-only")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ActualistTheme.secondaryText)
            Text(rule.summary(options: options))
                .foregroundStyle(ActualistTheme.primaryText)
                .multilineTextAlignment(.leading)
            if !rule.isEditable {
                Label(
                    rule.isScheduleOwned
                        ? "Managed by an Actual schedule"
                        : "Contains fields this version cannot safely edit",
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
            .appSwitcherPrivacyAwareDragIndicator()
            .appSwitcherPrivacyProtected(using: appState)
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
            Text("Future transactions will no longer be processed by this rule.")
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
