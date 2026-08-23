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
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.danger)
                    .settingsRowChrome()
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
                        Button {
                            editorTarget = RuleEditorTarget(rule: rule, fallbackPayeeID: payee.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(rule.isScheduleOwned ? "Schedule · Read-only" : rule.draft?.stage.displayName ?? "Read-only")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(ActualistTheme.secondaryText)
                                Text(rule.summary(options: viewModel.options))
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
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !rule.isScheduleOwned {
                                Button("Delete") { pendingDeleteRule = rule }
                                    .tint(ActualistTheme.danger)
                            }
                        }
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
        .sheet(item: $editorTarget) { target in
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
            .appSwitcherPrivacyProtected()
        }
        .confirmationDialog(
            "Delete Rule?",
            isPresented: Binding(
                get: { pendingDeleteRule != nil },
                set: { if !$0 { pendingDeleteRule = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let rule = pendingDeleteRule {
                Button("Delete Rule", role: .destructive) {
                    pendingDeleteRule = nil
                    Task { _ = await viewModel.delete(ruleID: rule.id, using: appState) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDeleteRule = nil }
        } message: {
            Text("Future transactions will no longer be processed by this rule.")
        }
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
