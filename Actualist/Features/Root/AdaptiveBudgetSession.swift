import Observation

/// Owns one window's models and serializes presentation handoffs so a late
/// compact load cannot replace a newer budget or month selection.
@MainActor
@Observable
final class AdaptiveBudgetSession {
    struct Context: Equatable {
        let mode: AdaptiveRootPresentationMode
        let budgetID: String?
    }

    private(set) var compactModel: BudgetViewModel
    let viewport: BudgetViewportModel
    private(set) var presentedContext: Context?
    private var requestedContext: Context?
    private var lastPresentedContext: Context?
    private var transitionTask: Task<Void, Never>?

    init(repository: any BudgetRepositoryProtocol) {
        let assignment = BudgetAssignmentWorkflow()
        compactModel = BudgetViewModel(assignmentWorkflow: assignment)
        viewport = BudgetViewportModel(repository: repository, assignmentWorkflow: assignment)
    }

    @discardableResult
    func update(mode: AdaptiveRootPresentationMode, budgetID: String?, appState: AppState) -> Task<Void, Never> {
        let context = Context(mode: mode, budgetID: budgetID)
        if context == requestedContext, isPrepared(for: context), let transitionTask { return transitionTask }
        requestedContext = context
        // Keep the current host until a same-budget resize is ready to present.
        // A budget switch must immediately stop presenting the previous budget.
        if presentedContext?.budgetID != budgetID { presentedContext = nil }
        let previous = transitionTask
        previous?.cancel()
        let task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.requestedContext == context else { return }
            await LaunchSignpost.measure(LaunchStage.sessionPrepare) {
                await self.prepare(context, appState: appState)
            }
            guard !Task.isCancelled, self.requestedContext == context else { return }
            self.presentedContext = context
            self.lastPresentedContext = context
        }
        transitionTask = task
        return task
    }

    /// A request is satisfied once the compact model owns a snapshot for the
    /// requested budget. Before that — a launch racing the database open, or a
    /// budget switch — the same request has to be prepared again instead of
    /// presenting an empty model.
    private func isPrepared(for context: Context) -> Bool {
        guard let budgetID = context.budgetID else { return true }
        return compactModel.loadedBudgetID == budgetID && compactModel.budgetMonth != nil
    }

    private func prepare(_ context: Context, appState: AppState) async {
        guard let budgetID = context.budgetID else { return }
        var restoredMonth: LoadedBudgetMonth?
        if compactModel.loadedBudgetID != budgetID {
            viewport.assignmentWorkflow.invalidate()
            // Consume the month the cached-budget restore already read instead of
            // recalculating it for the first frame. Only the selected budget's own
            // snapshot may seed a first frame, so a cached month keyed to any other
            // budget is ignored.
            if appState.settings.selectedBudgetID == budgetID {
                restoredMonth = appState.localFirstStore.cachedBudgetMonth(budgetID: budgetID)
            }
            compactModel = BudgetViewModel(
                initialMonth: restoredMonth,
                initialBudgetID: restoredMonth == nil ? nil : budgetID,
                assignmentWorkflow: viewport.assignmentWorkflow
            )
            compactModel.includeCarryoverCategoriesInOverspentAlerts =
                appState.settings.includeCarryoverCategoriesInOverspentAlerts
            if restoredMonth == nil {
                await compactModel.load(budgetID: budgetID, repository: viewport.repository)
            }
        }
        compactModel.includeCarryoverCategoriesInOverspentAlerts =
            appState.settings.includeCarryoverCategoriesInOverspentAlerts
        viewport.setShowHidden(appState.settings.showHiddenCategories)
        guard !Task.isCancelled else { return }
        switch context.mode {
        case .compact:
            if viewport.budgetID == budgetID {
                await viewport.prepareCompactState(compactModel)
            }
        case .sidebar:
            if viewport.budgetID != budgetID || lastPresentedContext?.mode == .compact {
                await viewport.adoptCompactState(compactModel, budgetID: budgetID, seed: restoredMonth)
            }
        }
    }
}
