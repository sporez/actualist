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

    private(set) var compactModel = BudgetViewModel()
    let viewport: BudgetViewportModel
    private(set) var presentedContext: Context?
    private var requestedContext: Context?
    private var lastPresentedContext: Context?
    private var transitionTask: Task<Void, Never>?

    init(repository: any BudgetRepositoryProtocol) {
        viewport = BudgetViewportModel(repository: repository)
    }

    @discardableResult
    func update(mode: AdaptiveRootPresentationMode, budgetID: String?, appState: AppState) -> Task<Void, Never> {
        let context = Context(mode: mode, budgetID: budgetID)
        if context == requestedContext, let transitionTask { return transitionTask }
        requestedContext = context
        presentedContext = nil
        let previous = transitionTask
        previous?.cancel()
        let task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.requestedContext == context else { return }
            await self.prepare(context, appState: appState)
            guard !Task.isCancelled, self.requestedContext == context else { return }
            self.presentedContext = context
            self.lastPresentedContext = context
        }
        transitionTask = task
        return task
    }

    private func prepare(_ context: Context, appState: AppState) async {
        guard let budgetID = context.budgetID else { return }
        if compactModel.loadedBudgetID != budgetID {
            compactModel = BudgetViewModel()
            compactModel.includeCarryoverCategoriesInOverspentAlerts =
                appState.settings.includeCarryoverCategoriesInOverspentAlerts
            await compactModel.load(budgetID: budgetID, repository: viewport.repository)
        }
        guard !Task.isCancelled else { return }
        switch context.mode {
        case .compact:
            if viewport.budgetID == budgetID {
                await viewport.prepareCompactState(compactModel)
            }
        case .sidebar:
            if viewport.budgetID != budgetID || lastPresentedContext?.mode == .compact {
                await viewport.adoptCompactState(compactModel, budgetID: budgetID)
            }
        }
    }
}
