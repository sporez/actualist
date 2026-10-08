import SwiftUI

/// Budget-wide rules list over the same `ruleRepository` cache as payee rules.
struct BudgetRulesView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = RulesListViewModel()
    @State private var editorTarget: RuleEditorTarget?
    @State private var pendingDeleteRule: ManagedRule?

    var body: some View {
        @Bindable var viewModel = viewModel
        List {
            if let errorMessage = viewModel.errorMessage {
                RulesListErrorText(message: errorMessage)
            }

            if viewModel.isLoading && viewModel.rules.isEmpty {
                ProgressView("Loading rules")
                    .settingsRowChrome()
            } else if viewModel.displayedRules(for: .all).isEmpty {
                ContentUnavailableView(
                    viewModel.searchText.isEmpty ? "No Rules" : "No Matching Rules",
                    systemImage: "wand.and.stars",
                    description: Text(
                        viewModel.searchText.isEmpty
                            ? "Create a rule to categorize or change matching transactions."
                            : "No rules match this search."
                    )
                )
            } else {
                ForEach(viewModel.sections(for: .all)) { section in
                    Section {
                        ForEach(section.rules) { rule in
                            ruleRow(rule)
                        }
                    } header: {
                        Text(section.stage.displayName)
                    }
                    .settingsSectionChrome()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .navigationTitle("Rules")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: "Search rules")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorTarget = RuleEditorTarget(rule: nil, fallbackPayeeID: "")
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create Rule")
                .disabled(viewModel.isSubmitting)
            }
        }
        .task { await viewModel.load(scope: .all, using: appState) }
        .refreshable { await viewModel.load(scope: .all, using: appState) }
        .ruleEditorSheet(target: $editorTarget, viewModel: viewModel)
        .sensoryFeedback(.success, trigger: viewModel.successFeedback)
    }

    private func ruleRow(_ rule: ManagedRule) -> some View {
        Button {
            editorTarget = RuleEditorTarget(rule: rule, fallbackPayeeID: rule.payeeIDs.sorted().first ?? "")
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
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if rule.isEditable {
                Button("Duplicate") {
                    Task { _ = await viewModel.duplicate(rule, using: appState) }
                }
                .tint(ActualistTheme.accent)
            }
        }
        .ruleDeleteConfirmation(pendingRule: $pendingDeleteRule, rule: rule, viewModel: viewModel)
    }
}
