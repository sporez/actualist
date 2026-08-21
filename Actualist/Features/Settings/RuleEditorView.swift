import SwiftUI

/// Sheet/navigation editor for a single rule. Owns screen-level composition
/// (sections, toolbars, read-only vs editable presentation, match-preview
/// section) and delegates draft editing to `RuleConditionEditor` /
/// `RuleActionEditor` and match-preview lifecycle to `RuleEditorViewModel`.
struct RuleEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let target: RuleEditorTarget
    let isSubmitting: Bool
    let errorMessage: String?
    let onSave: (RuleDraft) async -> Bool
    @State private var viewModel: RuleEditorViewModel

    init(
        target: RuleEditorTarget,
        isSubmitting: Bool,
        errorMessage: String?,
        onSave: @escaping (RuleDraft) async -> Bool
    ) {
        self.target = target
        self.isSubmitting = isSubmitting
        self.errorMessage = errorMessage
        self.onSave = onSave
        _viewModel = State(initialValue: RuleEditorViewModel(draft: target.initialDraft))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationStack {
            Form {
                if target.rule?.isEditable == false {
                    Section {
                        ForEach(
                            Array((target.rule?.readOnlyDetails(options: viewModel.options) ?? []).enumerated()),
                            id: \.offset
                        ) { _, detail in
                            Text(detail)
                        }
                    } header: {
                        Text("Read-only rule")
                    } footer: {
                        Text(
                            target.rule?.isScheduleOwned == true
                                ? "This rule is managed by an Actual schedule. It cannot be edited or deleted here."
                                : "This rule contains data Actualist cannot round-trip safely. It can still be deleted."
                        )
                    }
                } else {
                    Section("Order") {
                        RuleMenuPickerRow("Stage", selection: $viewModel.draft.stage) {
                            ForEach(RuleStage.allCases) { stage in
                                Text(stage.displayName).tag(stage)
                            }
                        }
                        RuleMenuPickerRow("Match", selection: $viewModel.draft.conditionsJoin) {
                            ForEach(RuleConditionJoin.allCases) { join in
                                Text(join == .and ? "All conditions" : "Any condition").tag(join)
                            }
                        }
                    }
                    .settingsSectionChrome()

                    Section("Conditions") {
                        ForEach($viewModel.draft.conditions) { $condition in
                            RuleConditionEditor(condition: $condition, options: viewModel.options)
                        }
                        .onDelete { viewModel.draft.conditions.remove(atOffsets: $0) }
                        Button("Add Condition", systemImage: "plus") {
                            viewModel.draft.conditions.append(
                                RuleCondition(field: "description", operation: "is", value: .string(target.fallbackPayeeID), type: "id")
                            )
                        }
                    }
                    .settingsSectionChrome()

                    Section("Actions") {
                        ForEach($viewModel.draft.actions) { $action in
                            RuleActionEditor(action: $action, options: viewModel.options)
                        }
                        .onDelete { viewModel.draft.actions.remove(atOffsets: $0) }
                        Button("Add Action", systemImage: "plus") {
                            viewModel.draft.actions.append(RuleAction(operation: "set", field: "category", value: .null, type: "id"))
                        }
                    }
                    .settingsSectionChrome()

                    matchingTransactionsSection
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.danger)
                        .settingsRowChrome()
                }
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .navigationTitle(target.rule == nil ? "New Rule" : target.rule?.isEditable == false ? "View Rule" : "Edit Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if target.rule?.isEditable != false {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task { if await onSave(viewModel.draft) { dismiss() } }
                        }
                        .disabled(!viewModel.draft.canRoundTripAndEvaluate || isSubmitting)
                    }
                }
            }
            .task {
                await viewModel.load(using: appState)
            }
            .onChange(of: viewModel.draft) {
                viewModel.scheduleMatchRefresh(using: appState)
            }
            .onDisappear {
                viewModel.cancelMatchRefresh()
            }
        }
    }

    @ViewBuilder
    private var matchingTransactionsSection: some View {
        Section {
            if viewModel.isLoadingMatches && viewModel.matchPreview == nil {
                ProgressView("Finding matching transactions")
            } else if let matchErrorMessage = viewModel.matchErrorMessage {
                Text(matchErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.danger)
            } else if viewModel.matchPreview?.totalCount == 0 {
                ContentUnavailableView(
                    "No Matching Transactions",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("No existing transactions match these conditions.")
                )
            } else if let preview = viewModel.matchPreview {
                ForEach(preview.transactions) { transaction in
                    RuleTransactionMatchRow(transaction: transaction)
                }
            }
        } header: {
            HStack {
                Text("This rule applies to the following transactions")
                Spacer()
                if let count = viewModel.matchPreview?.totalCount {
                    Text(count.formatted())
                }
            }
        } footer: {
            if let preview = viewModel.matchPreview,
               preview.totalCount > preview.transactions.count {
                Text("Showing the newest \(preview.transactions.count) of \(preview.totalCount) matches.")
            }
        }
        .settingsSectionChrome()
    }
}

/// A labeled menu-style picker row that pushes the inline picker to the trailing
/// edge and hides its system label in favor of the row's own title.
struct RuleMenuPickerRow<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    let content: () -> Content

    init(
        _ title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        _selection = selection
        self.content = content
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Picker("", selection: $selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel(title)
        }
    }
}
