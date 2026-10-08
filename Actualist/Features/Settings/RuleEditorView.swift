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
    @FocusState private var focusedField: RuleEditorFocus?
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
        Form {
            ReviewSheetListHeader(title: sheetTitle)
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
                        RuleConditionEditor(
                            condition: $condition,
                            options: viewModel.options,
                            focus: $focusedField
                        )
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
                        RuleActionEditor(
                            action: $action,
                            options: viewModel.options,
                            focus: $focusedField
                        )
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
        .scrollDismissesKeyboard(.interactively)
        .reviewSheetList()
        .actualistKeyboardDone(isVisible: focusedField != nil) {
            focusedField = nil
        }
        .reviewSheetBottomBar {
            if target.rule?.isEditable == false {
                ReviewSheetSecondaryButton(title: "Done", role: nil) { dismiss() }
            } else {
                ReviewSheetSecondaryButton { dismiss() }
                    .disabled(isSubmitting)
                ReviewSheetPrimaryButton {
                    focusedField = nil
                    Task { if await onSave(viewModel.draft) { dismiss() } }
                } label: {
                    Text("Save")
                }
                .disabled(!viewModel.draft.canRoundTripAndEvaluate || isSubmitting)
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
        .reviewSheetPresentation(appState: appState)
        .interactiveDismissDisabled(isSubmitting)
    }

    private var sheetTitle: String {
        target.rule == nil ? "New Rule" : target.rule?.isEditable == false ? "View Rule" : "Edit Rule"
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

enum RuleEditorFocus: Hashable {
    case value(UUID)
    case range(UUID, String)
    case listValue(UUID, Int)
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout())
        layout {
            Text(title)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer()
            }
            Picker("", selection: $selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel(title)
        }
    }
}
