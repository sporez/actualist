import SwiftUI

struct CategoryMonthDetailsView: View {
    let details: CategoryMonthDetails

    var body: some View {
        NavigationStack {
            CategoryMonthDetailsContent(details: details)
        }
        .presentationDetents([.large])
        .appSwitcherPrivacyAwareDragIndicator()
    }
}

struct CategoryMonthDetailsContent: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: CategoryMonthDetailsViewModel
    @State private var templateEditorTarget: BudgetTemplateEditorTarget?

    init(details: CategoryMonthDetails) {
        _viewModel = State(initialValue: CategoryMonthDetailsViewModel(details: details))
    }

    var body: some View {
        AccountTransactionsView(
            scope: .category(viewModel.details),
            onChanged: {
                Task { await viewModel.refresh(using: appState) }
            },
            categoryCarryoverIsEnabled: viewModel.isCarryoverEnabled,
            categoryNotePresentation: appState.settings.randomizedDisplayValuesEnabled
                ? nil
                : viewModel.categoryNotePresentation,
            categoryCarryoverIsUpdating: viewModel.isUpdatingCarryover,
            canEditCategoryCarryover: true,
            categoryCarryoverErrorMessage: viewModel.carryoverErrorMessage,
            onCategoryCarryoverChanged: { enabled in
                Task { await viewModel.setCarryover(enabled, using: appState) }
            },
            templateDoor: viewModel.templateDoor,
            onOpenTemplates: {
                templateEditorTarget = BudgetTemplateEditorTarget(
                    categoryID: viewModel.details.category.id,
                    categoryName: viewModel.details.category.name.actualistCategoryNameParts.name,
                    month: viewModel.details.month
                )
            }
        )
        .task { await viewModel.refresh(using: appState) }
        .onChange(of: appState.localDataRevision) {
            Task { await viewModel.refresh(using: appState) }
        }
        .onChange(of: appState.settings.randomizedDisplayValuesEnabled) {
            Task {
                await viewModel.refreshNote(using: appState)
                await viewModel.refreshTemplateDoor(using: appState)
            }
        }
        .sheet(item: $templateEditorTarget) { target in
            BudgetTemplateEditorView(target: target) {
                Task { await viewModel.refresh(using: appState) }
            }
            .appSwitcherPrivacyProtected(using: appState)
        }
    }
}
