import Foundation

/// Owns post-presentation work for one foreground app session.
///
/// Restoration marks the foreground session active; the Budget host separately
/// reports presentation. Enrichment starts only when both facts are true. The
/// completed task remains the session's deduplication token, while backgrounding
/// or replacing the presented budget cancels it deliberately.
@MainActor
final class LaunchWarmupCoordinator {

    private var isForeground = false
    private var presentedBudgetID: String?
    private var activeBudgetID: String?
    private var task: Task<Void, Never>?

    @discardableResult
    func beginForeground(appState: AppState) -> Task<Void, Never>? {
        isForeground = true
        return startIfReady(appState: appState)
    }

    @discardableResult
    func present(budgetID: String, appState: AppState) -> Task<Void, Never>? {
        if presentedBudgetID != budgetID {
            task?.cancel()
            task = nil
            activeBudgetID = nil
        }
        presentedBudgetID = budgetID
        return startIfReady(appState: appState)
    }
    func endPresentation() {
        presentedBudgetID = nil
        task?.cancel()
        task = nil
        activeBudgetID = nil
    }

    func endForeground() {
        isForeground = false
        task?.cancel()
        task = nil
        activeBudgetID = nil
    }

    private func startIfReady(appState: AppState) -> Task<Void, Never>? {
        guard isForeground, let presentedBudgetID else { return nil }
        if activeBudgetID == presentedBudgetID {
            return task
        }
        task?.cancel()
        activeBudgetID = presentedBudgetID
        let task = Task { [weak appState] in
            guard let appState, !Task.isCancelled else { return }
            await run(budgetID: presentedBudgetID, appState: appState)
        }
        self.task = task
        return task
    }

    private func run(budgetID: String, appState: AppState) async {
        guard appState.setupPhase == .ready,
              appState.settings.selectedBudgetID == budgetID,
              appState.localFirstStore.isOpen(budgetID: budgetID) else {
            return
        }

        async let notificationPreparation: Void = LaunchSignpost.measure(
            LaunchStage.notificationPreparation
        ) {
            await appState.prepareBackgroundTransactionNotifications()
        }

        await appState.localFirstStore.warmLaunchCaches(budgetID: budgetID)
        guard !Task.isCancelled,
              appState.setupPhase == .ready,
              appState.settings.selectedBudgetID == budgetID,
              appState.localFirstStore.isOpen(budgetID: budgetID) else {
            _ = await notificationPreparation
            return
        }
        _ = await LaunchSignpost.measure(LaunchStage.foregroundSync) {
            await appState.refreshLocalFirstData(budgetID: budgetID, force: false)
        }
        _ = await notificationPreparation
    }
}
