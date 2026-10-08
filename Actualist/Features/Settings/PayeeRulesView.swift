import SwiftUI

/// The payee-associated rules list screen: loads, adds, edits, and deletes rules
/// scoped to a single payee. Renders display state and calls view-model intents;
/// the editor sheet itself lives in `RuleEditorView`.
struct PayeeRulesView: View {
    @Environment(AppState.self) private var appState
    let payee: ManagedPayee
    @State private var viewModel = RulesListViewModel()
    @State private var editorTarget: RuleEditorTarget?
    @State private var pendingDeleteRule: ManagedRule?

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                RulesListErrorText(message: errorMessage)
            }

            Section {
                if viewModel.isLoading && viewModel.rules.isEmpty {
                    ProgressView("Loading rules")
                } else if viewModel.displayedRules(for: .payee(payee.id)).isEmpty {
                    ContentUnavailableView(
                        "No Rules",
                        systemImage: "wand.and.stars",
                        description: Text("Create a rule that applies whenever this payee is used.")
                    )
                } else {
                    ForEach(viewModel.displayedRules(for: .payee(payee.id))) { rule in
                        ruleRow(rule)
                    }
                }
            } header: {
                Text(payee.isTransfer ? "Transfer Rules" : "Associated Rules")
            }
            .settingsSectionChrome()
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .navigationTitle("Rules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorTarget = RuleEditorTarget(rule: nil, fallbackPayeeID: payee.id)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create Rule")
                .disabled(viewModel.isSubmitting)
            }
        }
        .task { await viewModel.load(scope: .payee(payee.id), using: appState) }
        .refreshable { await viewModel.load(scope: .payee(payee.id), using: appState) }
        .ruleEditorSheet(target: $editorTarget, viewModel: viewModel)
        .sensoryFeedback(.success, trigger: viewModel.successFeedback)
    }

    private func ruleRow(_ rule: ManagedRule) -> some View {
        Button {
            editorTarget = RuleEditorTarget(rule: rule, fallbackPayeeID: payee.id)
        } label: {
            RuleRowLabel(rule: rule, options: viewModel.options)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !rule.isScheduleOwned {
                Button("Delete") { pendingDeleteRule = rule }
                    .tint(ActualistTheme.danger)
            }
        }
        .ruleDeleteConfirmation(pendingRule: $pendingDeleteRule, rule: rule, viewModel: viewModel)
    }
}

/// Identifiable presentation target for the rule-editor sheet: the existing
/// rule to edit (or `nil` for a new rule) and the payee used to seed a new
/// rule's default condition. Widened to internal so `RuleEditorView` (now in its
/// own file) can consume it; it remains a presentation bridge, not a model.
struct RuleEditorTarget: Identifiable {
    let id = UUID()
    let rule: ManagedRule?
    let fallbackPayeeID: String

    var initialDraft: RuleDraft {
        if let draft = rule?.draft { return draft }
        if fallbackPayeeID.isEmpty { return .blank }
        return .categoryRule(payeeID: fallbackPayeeID)
    }
}
