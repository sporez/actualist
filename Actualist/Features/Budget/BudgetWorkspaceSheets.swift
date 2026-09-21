import SwiftUI

struct BudgetWorkspaceSheets: ViewModifier {
    @Environment(AppState.self) private var appState
    @Bindable var actions: BudgetWorkspaceActions
    let viewport: BudgetViewportModel

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { actions.sheet }, set: { if $0 == nil { actions.dismissSheet() } }), onDismiss: {
                Task { await viewport.refreshVisibleMonths() }
            }) { sheet in
                sheetContent(sheet)
                    .appSwitcherPrivacyProtected(using: appState)
            }
            .modifier(BudgetTemplateConfirmationModifier(
                confirmation: Binding(get: { actions.confirmation }, set: { actions.setConfirmation($0) }),
                categoryID: actions.actionCategoryID,
                month: actions.actionMonth,
                modeIdentity: viewport.modeIdentity,
                apply: { confirmation, reviewedMode in
                    Task { await actions.applyConfirmation(confirmation, reviewedMode: reviewedMode, using: appState) }
                }
            ))
    }

    @ViewBuilder
    private func sheetContent(_ sheet: BudgetWorkspaceSheet) -> some View {
        switch sheet {
        case .history:
            HistoryView()
        case .uncategorized(let month):
            UncategorizedTransactionsView(
                month: month,
                cachedSnapshot: nil,
                onChanged: { Task { await viewport.refreshVisibleMonths() } },
                onResolvedAll: { actions.dismissSheet() }
            )
        case .overspent:
            if let model = actions.actionModel {
                BudgetOverspentCategoriesView(viewModel: model, isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled)
            }
        case .moveMoney:
            if let model = actions.actionModel {
                BudgetMoveMoneyView(viewModel: model, onSaved: {
                    Task { await viewport.refreshVisibleMonths() }
                })
            }
        case .note(let target):
            if let budgetID = viewport.budgetID {
                EntityNotesView(
                    target: target,
                    budgetID: budgetID,
                    isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
                    repository: appState.localFirstStore,
                    onSaved: { Task { await viewport.refreshVisibleMonths() } }
                )
            }
        case .templates(let target):
            BudgetTemplateEditorView(target: target) {
                Task { await viewport.refreshVisibleMonths() }
            }
        case .categoryLifecycle(let lifecycleSheet):
            switch lifecycleSheet {
            case .reorder:
                BudgetCategoryReorderSheet(
                    controller: actions.categoryLifecycle,
                    selectedMonth: actions.actionMonth,
                    budgetID: actions.actionBudgetID,
                    repository: viewport.repository,
                    onSaved: {}
                )
            case .deleteCategory, .deleteGroup:
                BudgetCategoryDeleteSheet(
                    controller: actions.categoryLifecycle,
                    selectedMonth: actions.actionMonth,
                    budgetID: actions.actionBudgetID,
                    repository: viewport.repository,
                    onDeleted: {}
                )
            default:
                BudgetCategoryNameSheet(
                    controller: actions.categoryLifecycle,
                    sheet: lifecycleSheet,
                    selectedMonth: actions.actionMonth,
                    budgetID: actions.actionBudgetID,
                    repository: viewport.repository,
                    onSaved: {}
                )
            }
        }
    }
}
