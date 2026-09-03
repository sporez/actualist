import SwiftUI

struct BudgetTemplatesBrowserView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = BudgetTemplatesBrowserViewModel()
    @State private var editorTarget: BudgetTemplateEditorTarget?
    @State private var isPickerPresented = false
    @State private var pendingPickerCategoryID: String?

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.danger)
                    .settingsRowChrome()
            }

            if viewModel.isLoading && !viewModel.hasTemplates {
                ProgressView("Loading templates")
                    .settingsRowChrome()
            } else if !viewModel.hasTemplates {
                ContentUnavailableView(
                    viewModel.emptyTitle,
                    systemImage: "sparkles",
                    description: Text(viewModel.emptyDescription)
                )
            } else {
                ForEach(viewModel.visibleSections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            categoryRow(row)
                        }
                    }
                    .settingsSectionChrome()
                }

                if let hiddenSection = viewModel.hiddenSection {
                    Section {
                        Button {
                            viewModel.toggleHiddenSection()
                        } label: {
                            HStack {
                                Text(hiddenSection.title)
                                Spacer()
                                Text("\(hiddenSection.rows.count)")
                                    .foregroundStyle(ActualistTheme.secondaryText)
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(ActualistTheme.secondaryText)
                                    .rotationEffect(
                                        .degrees(viewModel.isHiddenSectionExpanded ? 0 : -90)
                                    )
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Hidden")
                        .accessibilityValue(
                            viewModel.isHiddenSectionExpanded ? "Expanded" : "Collapsed"
                        )

                        if viewModel.isHiddenSectionExpanded {
                            ForEach(hiddenSection.rows) { row in
                                categoryRow(row)
                            }
                        }
                    }
                    .settingsSectionChrome()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPickerPresented = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Template")
                .disabled(!viewModel.canAdd)
            }
        }
        .task(id: appState.settings.selectedBudgetID) {
            await load()
        }
        .onChange(of: appState.settings.randomizedDisplayValuesEnabled) { _, enabled in
            viewModel.isPrivacyModeEnabled = enabled
        }
        .refreshable {
            await load()
        }
        .sheet(item: $editorTarget, onDismiss: {
            Task { await load() }
        }) { target in
            BudgetTemplateEditorView(target: target) {
                Task { await load() }
            }
            .environment(appState)
            .appSwitcherPrivacyProtected()
        }
        .sheet(isPresented: $isPickerPresented, onDismiss: {
            presentPendingPickerCategory()
        }) {
            BudgetTemplatesCategoryPickerView(
                visibleSections: viewModel.pickerVisibleSections,
                hiddenSection: viewModel.pickerHiddenSection
            ) { categoryID in
                pendingPickerCategoryID = categoryID
            }
            .environment(appState)
            .appSwitcherPrivacyProtected()
        }
    }

    private func categoryRow(_ row: BudgetTemplatesBrowserRow) -> some View {
        Button {
            editorTarget = viewModel.editorTarget(for: row.id)
        } label: {
            LabeledContent(row.title) {
                Text(row.subtitle)
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func presentPendingPickerCategory() {
        guard let categoryID = pendingPickerCategoryID else {
            return
        }
        pendingPickerCategoryID = nil
        editorTarget = viewModel.editorTarget(for: categoryID)
    }

    private func load() async {
        viewModel.isPrivacyModeEnabled = appState.settings.randomizedDisplayValuesEnabled
        await viewModel.load(
            repository: appState.budgetRepository,
            budgetID: appState.settings.selectedBudgetID
        )
    }
}

struct BudgetTemplatesCategoryPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let visibleSections: [BudgetTemplatesBrowserSection]
    let hiddenSection: BudgetTemplatesBrowserSection?
    let onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                if visibleSections.isEmpty && hiddenSection == nil {
                    ContentUnavailableView(
                        "No Categories",
                        systemImage: "sparkles",
                        description: Text("Every category already has a template.")
                    )
                } else {
                    ForEach(visibleSections) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in
                                pickerRow(row)
                            }
                        }
                        .settingsSectionChrome()
                    }

                    if let hiddenSection {
                        Section(hiddenSection.title) {
                            ForEach(hiddenSection.rows) { row in
                                pickerRow(row)
                            }
                        }
                        .settingsSectionChrome()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .appSwitcherPrivacyAwareDragIndicator()
    }

    private func pickerRow(_ row: BudgetTemplatesBrowserRow) -> some View {
        Button(row.title) {
            onSelect(row.id)
            dismiss()
        }
        .foregroundStyle(ActualistTheme.primaryText)
    }
}
