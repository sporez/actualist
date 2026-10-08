import Foundation

struct AccountLifecycleRouteReceipt: Identifiable, Equatable {
    let id = UUID()
    let identity: AccountLifecycleIdentity
    let budgetSessionGeneration: Int
    let operation: AccountLifecycleOperation
}

/// Reconciles navigation only after a committed lifecycle operation in this session.
@MainActor
enum AccountLifecycleRouting {
    static func completionHandler(
        using appState: AppState
    ) -> @MainActor (AccountLifecycleIdentity, AccountLifecycleOutcome) -> Void {
        let generation = appState.localFirstStore.budgetSessionGeneration
        return { [weak appState] identity, outcome in
            guard let appState,
                  appState.settings.selectedBudgetID == identity.budgetID,
                  appState.localFirstStore.budgetSessionGeneration == generation,
                  outcome.account.id == identity.accountID else { return }
            appState.routeCoordinator.publishAccountLifecycleReceipt(
                AccountLifecycleRouteReceipt(
                    identity: identity,
                    budgetSessionGeneration: generation,
                    operation: outcome.operation
                )
            )
            appState.recordLocalDataMutation()
        }
    }

    static func consume(
        receiptID: UUID,
        using appState: AppState,
        selection: AdaptiveRootDestination?
    ) -> AdaptiveRootDestination? {
        guard let receipt = appState.routeCoordinator.consumeAccountLifecycleReceipt(id: receiptID),
              receipt.identity.budgetID == appState.settings.selectedBudgetID,
              receipt.budgetSessionGeneration == appState.localFirstStore.budgetSessionGeneration else {
            return selection
        }
        let accountID = receipt.identity.accountID
        switch receipt.operation {
        case .close, .delete:
            if let index = appState.accountNavigationPath.firstIndex(where: { $0.id == accountID }) {
                appState.accountNavigationPath.removeSubrange(index...)
            }
            if case .account(let account) = selection, account.id == accountID {
                return .accounts
            }
        case .rename, .reopen:
            guard let current = appState.accountRepository
                .accountDisplays(budgetID: receipt.identity.budgetID)
                .first(where: { $0.id == accountID })?.account else { return selection }
            appState.accountNavigationPath = appState.accountNavigationPath.map {
                $0.id == accountID ? current : $0
            }
            if case .account(let account) = selection, account.id == accountID {
                return .account(current)
            }
        }
        return selection
    }
}
