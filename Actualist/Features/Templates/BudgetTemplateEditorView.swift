import SwiftUI

struct BudgetTemplateEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let target: BudgetTemplateEditorTarget
    let onSaved: () -> Void

    @FocusState private var focusedField: BudgetTemplateEditorFocus?
    @State private var viewModel: BudgetTemplateEditorViewModel

    init(target: BudgetTemplateEditorTarget, onSaved: @escaping () -> Void = {}) {
        self.target = target
        self.onSaved = onSaved
        _viewModel = State(initialValue: BudgetTemplateEditorViewModel(target: target))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationStack {
            Form {
                if viewModel.phase == .loading {
                    ProgressView("Loading templates")
                        .frame(maxWidth: .infinity)
                        .settingsRowChrome()
                } else {
                    if let reason = viewModel.lock.testerFacingReason {
                        Section {
                            Text(reason)
                        }
                        .settingsSectionChrome()
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("This month", value: viewModel.totalContributionText)
                                .monospacedDigit()
                            Text(viewModel.previewStatusText)
                                .font(.footnote)
                                .foregroundStyle(ActualistTheme.secondaryText)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2, reservesSpace: true)
                        }
                        if viewModel.isPrivacyModeEnabled {
                            Text("Amounts and notes are hidden in Sample Values. Disable it to edit those fields.")
                                .font(.footnote)
                                .foregroundStyle(ActualistTheme.secondaryText)
                        }
                    } footer: {
                        Text(target.categoryName)
                    }
                    .settingsSectionChrome()

                    ForEach(Array(viewModel.editor.items.enumerated()), id: \.element.id) { index, item in
                        BudgetTemplateEditorItemSection(
                            item: item,
                            index: index,
                            viewModel: viewModel,
                            focus: $focusedField
                        )
                    }

                    if viewModel.isEditable {
                        Section {
                            Menu("Add Template", systemImage: "plus") {
                                ForEach(viewModel.editor.addableKinds) { kind in
                                    Button(kind.title) {
                                        viewModel.edit(.add(kind))
                                    }
                                }
                            }
                        }
                        .settingsSectionChrome()
                    }

                    if viewModel.isEditable && !viewModel.authoringIssueMessages.isEmpty {
                        Section {
                            ForEach(
                                Array(viewModel.authoringIssueMessages.enumerated()),
                                id: \.offset
                            ) { _, message in
                                Label(message, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(ActualistTheme.danger)
                            }
                        }
                        .settingsSectionChrome()
                    }

                    if let dryRunErrorMessage = viewModel.dryRunErrorMessage {
                        Text(dryRunErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(ActualistTheme.danger)
                            .settingsRowChrome()
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(ActualistTheme.danger)
                            .settingsRowChrome()
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .tint(ActualistTheme.accent)
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .navigationTitle(viewModel.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaBar(edge: .bottom, alignment: .trailing) {
                if focusedField != nil {
                    Button("Done") { focusedField = nil }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .tint(ActualistTheme.chromeForeground)
                        .padding(.trailing, 16)
                        .padding(.bottom, 12)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(viewModel.isEditable ? "Cancel" : "Done") {
                        viewModel.cancel()
                        dismiss()
                    }
                    .disabled(viewModel.phase == .saving)
                }
                if viewModel.isEditable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task { await save() }
                        }
                        .disabled(!viewModel.canSave || viewModel.phase == .saving)
                    }
                }
            }
        }
        .onChange(of: focusedField) { _, field in
            viewModel.inputFocusChanged(to: field?.inputKey)
        }
        .interactiveDismissDisabled(viewModel.phase == .saving)
        .environment(\.budgetCurrency, viewModel.editor.currency)
        .task(id: appState.settings.selectedBudgetID) {
            await viewModel.load(repository: appState.budgetRepository, budgetID: appState.settings.selectedBudgetID)
        }
        .onChange(of: appState.settings.randomizedDisplayValuesEnabled, initial: true) { _, enabled in
            viewModel.isPrivacyModeEnabled = enabled
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    private func save() async {
        guard await viewModel.save() else {
            return
        }
        onSaved()
        dismiss()
    }
}
