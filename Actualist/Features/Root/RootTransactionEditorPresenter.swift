import Observation

@MainActor
@Observable
final class RootTransactionEditorPresenter {
    var presentation: TransactionEditorSession?

    @discardableResult
    func present(
        using appState: AppState,
        request: TransactionEditorPresentation = .create,
        account: ActualAccount? = nil,
        categoryName: String? = nil,
        prefill: ShortcutEditorPrefill? = nil
    ) -> Bool {
        guard let context = TransactionEditorSession.Context(appState: appState) else { return false }
        return present(context: context, request: request, account: account, categoryName: categoryName, prefill: prefill)
    }

    @discardableResult
    func present(
        context: TransactionEditorSession.Context,
        request: TransactionEditorPresentation = .create,
        account: ActualAccount? = nil,
        categoryName: String? = nil,
        prefill: ShortcutEditorPrefill? = nil
    ) -> Bool {
        guard presentation == nil else { return false }
        presentation = TransactionEditorSession(
            context: context, request: request, account: account,
            categoryName: categoryName, prefill: prefill
        )
        return true
    }

    func reconcile(using appState: AppState) {
        guard presentation?.context != TransactionEditorSession.Context(appState: appState) else { return }
        presentation?.invalidate()
        presentation = nil
    }

    @discardableResult
    func consumeNewTransaction(using appState: AppState) -> Bool {
        let coordinator = appState.routeCoordinator
        guard case .newTransaction(let prefill) = coordinator.pendingRoute,
              present(using: appState, prefill: prefill) else { return false }
        _ = coordinator.consume()
        return true
    }
}
