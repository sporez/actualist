import SwiftUI

struct BudgetTemplateEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let target: BudgetTemplateEditorTarget
    let onSaved: () -> Void

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

                    Section {
                        LabeledContent("This month", value: viewModel.totalContributionText)
                    } footer: {
                        Text(target.categoryName)
                    }
                    .settingsSectionChrome()

                    ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                        BudgetTemplateEditorItemSection(
                            item: item,
                            index: index,
                            viewModel: viewModel
                        )
                    }

                    if viewModel.isEditable {
                        Section {
                            Menu("Add Template", systemImage: "plus") {
                                ForEach(viewModel.addableKinds) { kind in
                                    Button(kind.title) {
                                        viewModel.add(kind)
                                    }
                                }
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
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .navigationTitle(viewModel.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
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
        .interactiveDismissDisabled(viewModel.phase == .saving)
        .environment(\.budgetCurrency, viewModel.currency)
        .task {
            await load()
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    private func load() async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            viewModel.errorMessage = "No budget is selected."
            return
        }
        viewModel.isPrivacyModeEnabled = appState.settings.randomizedDisplayValuesEnabled
        await viewModel.load(repository: appState.budgetRepository, budgetID: budgetID)
    }

    private func save() async {
        guard await viewModel.save() else {
            return
        }
        onSaved()
        dismiss()
    }
}
