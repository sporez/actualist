import Observation

enum BudgetWorkspaceSheet: Identifiable, Equatable {
    case history
    case uncategorized(String)
    case overspent
    case moveMoney
    case note(ActualNoteTarget)
    case templates(BudgetTemplateEditorTarget)
    case categoryLifecycle(BudgetCategoryLifecycleSheet)

    var id: String {
        switch self {
        case .history: "history"
        case .uncategorized(let month): "uncategorized:\(month)"
        case .overspent: "overspent"
        case .moveMoney: "move-money"
        case .note(let target): "note:\(target.id)"
        case .templates(let target): "templates:\(target.id)"
        case .categoryLifecycle(let sheet): "category-lifecycle:\(sheet.id)"
        }
    }
}

/// Owns action and sheet state for the wide budget workspace. The grid stays
/// responsible for rendering cells; this object captures the month/category
/// context before presenting an existing workflow or editor.
@MainActor
@Observable
final class BudgetWorkspaceActions {
    let viewport: BudgetViewportModel

    private(set) var sheet: BudgetWorkspaceSheet?
    private(set) var actionModel: BudgetViewModel?
    private(set) var confirmation: BudgetTemplateConfirmation?
    private(set) var actionMonth: String?
    private(set) var actionCategoryID: String?
    private(set) var actionBudgetID: String?
    var errorMessage: String? {
        actionModel?.errorMessage ?? visibilityWorkflow.errorMessage ?? categoryLifecycle.errorMessage
    }
    var isSubmitting: Bool {
        actionModel?.isLoading == true || visibilityWorkflow.isSubmitting || categoryLifecycle.isSubmitting
    }

    let categoryLifecycle = BudgetCategoryLifecycleController()

    private let visibilityWorkflow = BudgetCategoryVisibilityWorkflow()
    private var includeCarryoverCategoriesInOverspentAlerts: Bool

    init(viewport: BudgetViewportModel, includeCarryoverCategoriesInOverspentAlerts: Bool = false) {
        self.viewport = viewport
        self.includeCarryoverCategoriesInOverspentAlerts = includeCarryoverCategoriesInOverspentAlerts
    }

    func updateIncludeCarryover(_ enabled: Bool) {
        includeCarryoverCategoriesInOverspentAlerts = enabled
        actionModel?.includeCarryoverCategoriesInOverspentAlerts = enabled
    }

    func activate(using appState: AppState, compactModel: BudgetViewModel, monthCount: Int) async {
        guard let budgetID = appState.settings.selectedBudgetID else { return }
        await viewport.activate(budgetID: budgetID, compactModel: compactModel, monthCount: monthCount)
        guard !Task.isCancelled, appState.settings.selectedBudgetID == budgetID else { return }
        await applyRoute(using: appState)
    }

    func refresh(using appState: AppState) async {
        guard let budgetID = viewport.budgetID,
              budgetID == appState.settings.selectedBudgetID else { return }
        _ = await appState.refreshLocalFirstData(budgetID: budgetID, force: true)
        guard viewport.budgetID == budgetID else { return }
        await viewport.refreshVisibleMonths()
    }

    func openAlert(_ alert: BudgetAlert, month: String) {
        actionMonth = month
        switch alert.kind {
        case .toBudget:
            return
        case .uncategorizedTransactions:
            sheet = .uncategorized(month)
        case .overspending:
            prepareActionModel(for: month)
            sheet = .overspent
        }
    }

    func openHistory() {
        clearActionContext()
        sheet = .history
    }

    func openCreateCategory() {
        presentCategoryLifecycle(.createCategory(
            groups: categoryLifecycleGroups,
            isTrackingBudget: viewport.isTrackingBudget
        ))
    }

    func openCreateGroup() {
        presentCategoryLifecycle(.createGroup)
    }

    func openRenameCategory(_ category: BudgetMonthCategory) {
        guard viewport.isTrackingBudget || !category.isIncome else { return }
        presentCategoryLifecycle(.renameCategory(category, isTrackingBudget: viewport.isTrackingBudget))
    }

    func openRenameGroup(_ group: BudgetMonthCategoryGroup) {
        guard viewport.isTrackingBudget || !group.isIncome else { return }
        presentCategoryLifecycle(.renameGroup(group, isTrackingBudget: viewport.isTrackingBudget))
    }

    func openCategoryReorder() {
        presentCategoryLifecycle(.reorder(
            groups: categoryLifecycleGroups,
            isTrackingBudget: viewport.isTrackingBudget
        ))
    }

    func requestDeleteCategory(_ category: BudgetMonthCategory) async {
        clearActionContext()
        actionMonth = viewport.anchorMonth
        actionBudgetID = viewport.budgetID
        let result = await categoryLifecycle.requestDeleteCategory(
            category,
            groups: categoryLifecycleGroups,
            isTrackingBudget: viewport.isTrackingBudget,
            selectedMonth: actionMonth,
            budgetID: actionBudgetID,
            repository: viewport.repository
        )
        await handleDeleteRequest(result)
    }

    func requestDeleteGroup(_ group: BudgetMonthCategoryGroup) async {
        clearActionContext()
        actionMonth = viewport.anchorMonth
        actionBudgetID = viewport.budgetID
        let result = await categoryLifecycle.requestDeleteGroup(
            group,
            groups: categoryLifecycleGroups,
            isTrackingBudget: viewport.isTrackingBudget,
            selectedMonth: actionMonth,
            budgetID: actionBudgetID,
            repository: viewport.repository
        )
        await handleDeleteRequest(result)
    }

    func openMonthNote(_ month: String) {
        guard let target = ActualNoteTarget.budgetMonth(month: month, title: month) else { return }
        actionMonth = month
        sheet = .note(target)
    }

    func openCategoryNote(_ category: BudgetMonthCategory, month: String) {
        guard let target = ActualNoteTarget.category(
            id: category.id,
            title: category.name.actualistCategoryNameParts.name
        ) else { return }
        actionMonth = month
        actionCategoryID = category.id
        sheet = .note(target)
    }

    func openCategoryNote(_ category: BudgetMonthCategory) {
        guard let month = viewport.selectedCategoryMonth ?? viewport.anchorMonth else { return }
        openCategoryNote(category, month: month)
    }

    func openGroupNote(_ group: BudgetMonthCategoryGroup, month: String) {
        guard let target = ActualNoteTarget.categoryGroup(id: group.id, title: group.name) else { return }
        actionMonth = month
        sheet = .note(target)
    }

    func openGroupNote(_ group: BudgetMonthCategoryGroup) {
        guard let month = viewport.anchorMonth else { return }
        openGroupNote(group, month: month)
    }

    func openTemplates(_ category: BudgetMonthCategory, month: String) {
        viewport.cancelAssignmentEditing()
        actionMonth = month
        actionCategoryID = category.id
        sheet = .templates(
            BudgetTemplateEditorTarget(
                categoryID: category.id,
                categoryName: category.name.actualistCategoryNameParts.name,
                month: month
            )
        )
    }

    func requestMonthTemplate(_ mode: BudgetTemplateApplicationMode, month: String) {
        viewport.cancelAssignmentEditing()
        actionMonth = month
        actionCategoryID = nil
        prepareActionModel(for: month)
        actionModel?.cancelAssignmentEditing()
        confirmation = mode == .overwrite ? .monthOverwrite : .monthFillEmpty
    }

    func requestCategoryTemplate(_ cell: BudgetViewportModel.SelectedCell) {
        viewport.cancelAssignmentEditing()
        actionMonth = cell.month
        actionCategoryID = cell.categoryID
        prepareActionModel(for: cell.month)
        guard let category = actionModel?.budgetMonth?.categoryGroups
            .flatMap(\.categories).first(where: { $0.id == cell.categoryID }) else {
            actionModel = nil
            return
        }
        actionModel?.beginAssignmentEditing(for: category)
        confirmation = .category
    }

    func beginMoveMoney(_ cell: BudgetViewportModel.SelectedCell) {
        guard !viewport.isTrackingBudget else { return }
        viewport.cancelAssignmentEditing()
        actionMonth = cell.month
        actionCategoryID = cell.categoryID
        prepareActionModel(for: cell.month)
        actionModel?.beginMoveMoney(for: cell.categoryID)
        sheet = .moveMoney
    }

    func setConfirmation(_ confirmation: BudgetTemplateConfirmation?) {
        self.confirmation = confirmation
    }

    func applyConfirmation(
        _ confirmation: BudgetTemplateConfirmation,
        reviewRevision: BudgetTemplateReviewRevision,
        using appState: AppState
    ) async {
        guard let actionModel, let actionBudgetID, let actionMonth else {
            self.confirmation = nil
            return
        }

        self.confirmation = nil
        guard viewport.budgetID == actionBudgetID,
              appState.settings.selectedBudgetID == actionBudgetID,
              actionMonth == reviewRevision.month else { return }
        let succeeded = await BudgetTemplateWorkflow.applyReviewed(
            confirmation,
            revision: reviewRevision,
            model: actionModel,
            budgetID: actionBudgetID,
            repository: viewport.repository
        )
        if succeeded, viewport.budgetID == actionBudgetID, viewport.snapshot(for: actionMonth) != nil {
            await viewport.refreshVisibleMonths()
        }
    }

    func setCategoryHidden(
        _ isHidden: Bool,
        category: BudgetMonthCategory,
        group: BudgetMonthCategoryGroup,
        month: String,
        using appState: AppState
    ) async {
        guard let budgetID = viewport.budgetID,
              budgetID == appState.settings.selectedBudgetID,
              await visibilityWorkflow.setCategoryHidden(
            isHidden,
            categoryID: category.id,
            groupHidden: BudgetCategoryVisibility.isHidden(group.hidden),
            selectedMonth: month,
            budgetID: budgetID,
            repository: appState.budgetRepository
        ) != nil else { return }
        guard viewport.budgetID == budgetID, appState.settings.selectedBudgetID == budgetID else { return }
        await viewport.refreshVisibleMonths()
    }

    func setGroupHidden(
        _ isHidden: Bool,
        group: BudgetMonthCategoryGroup,
        month: String,
        using appState: AppState
    ) async {
        guard let budgetID = viewport.budgetID,
              budgetID == appState.settings.selectedBudgetID,
              await visibilityWorkflow.setGroupHidden(
            isHidden,
            group: group,
            selectedMonth: month,
            budgetID: budgetID,
            repository: appState.budgetRepository
        ) != nil else { return }
        guard viewport.budgetID == budgetID, appState.settings.selectedBudgetID == budgetID else { return }
        await viewport.refreshVisibleMonths()
    }

    func toggleCategoryHidden(
        _ category: BudgetMonthCategory,
        in group: BudgetMonthCategoryGroup,
        using appState: AppState
    ) async {
        guard let month = viewport.anchorMonth else { return }
        await toggleCategoryHidden(category, in: group, month: month, using: appState)
    }

    func toggleGroupHidden(_ group: BudgetMonthCategoryGroup, using appState: AppState) async {
        guard let month = viewport.anchorMonth else { return }
        await toggleGroupHidden(group, month: month, using: appState)
    }

    func toggleCategoryHidden(
        _ category: BudgetMonthCategory,
        in group: BudgetMonthCategoryGroup,
        month: String,
        using appState: AppState
    ) async {
        await setCategoryHidden(
            !BudgetCategoryVisibility.isHidden(category.hidden),
            category: category,
            group: group,
            month: month,
            using: appState
        )
    }

    func toggleGroupHidden(
        _ group: BudgetMonthCategoryGroup,
        month: String,
        using appState: AppState
    ) async {
        await setGroupHidden(
            !BudgetCategoryVisibility.isHidden(group.hidden),
            group: group,
            month: month,
            using: appState
        )
    }

    func dismissSheet() {
        viewport.cancelAssignmentEditing()
        categoryLifecycle.cancel()
        clearActionContext()
    }

    /// Applies only budget routes. Settings remains owned by the root shell,
    /// so an unrelated settings route is deliberately left pending for it.
    func applyRoute(using appState: AppState) async {
        guard let route = appState.routeCoordinator.pendingRoute else { return }
        switch route {
        case .history:
            openHistory()
            _ = appState.routeCoordinator.consume(if: { $0 == route })
        case .uncategorized(let month):
            actionMonth = month
            sheet = .uncategorized(month)
            _ = appState.routeCoordinator.consume(if: { $0 == route })
        case .category(let categoryID, let month):
            guard let budgetID = appState.settings.selectedBudgetID else { return }
            await viewport.load(budgetID: budgetID, anchorMonth: month)
            guard appState.routeCoordinator.pendingRoute == route,
                  viewport.budgetID == budgetID,
                  viewport.snapshot(for: month)?.month.categoryGroups
                    .flatMap(\.categories).contains(where: { $0.id == categoryID }) == true else {
                return
            }
            viewport.selectCategory(categoryID: categoryID, month: month)
            actionMonth = month
            actionCategoryID = categoryID
            _ = appState.routeCoordinator.consume(if: { $0 == route })
        default:
            return
        }
    }

    private func prepareActionModel(for month: String) {
        guard let snapshot = viewport.snapshot(for: month) else {
            actionModel = nil
            return
        }
        actionModel = BudgetViewModel(
            initialMonth: snapshot,
            initialBudgetID: viewport.budgetID
        )
        actionBudgetID = viewport.budgetID
        actionModel?.includeCarryoverCategoriesInOverspentAlerts = includeCarryoverCategoriesInOverspentAlerts
    }

    private var categoryLifecycleGroups: [BudgetMonthCategoryGroup] {
        guard let month = viewport.anchorMonth else { return [] }
        return viewport.snapshot(for: month)?.month.categoryGroups ?? []
    }

    private func presentCategoryLifecycle(_ lifecycleSheet: BudgetCategoryLifecycleSheet) {
        clearActionContext()
        categoryLifecycle.prepare(lifecycleSheet)
        actionMonth = viewport.anchorMonth
        actionBudgetID = viewport.budgetID
        sheet = .categoryLifecycle(lifecycleSheet)
    }

    private func handleDeleteRequest(_ result: BudgetCategoryDeletionRequestResult) async {
        switch result {
        case .review(let lifecycleSheet):
            sheet = .categoryLifecycle(lifecycleSheet)
        case .deleted:
            clearActionContext()
            await viewport.refreshVisibleMonths()
        case .failed:
            break
        }
    }

    private func clearActionContext() {
        sheet = nil
        actionModel = nil
        confirmation = nil
        actionMonth = nil
        actionCategoryID = nil
        actionBudgetID = nil
    }
}
