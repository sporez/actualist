import Observation

@MainActor
@Observable
final class RootTransactionEditorPresenter {
    var presentation: TransactionEditorSession?
    let sharedLinks = SharedTransactionLinkResolver()

    private struct SharedEdit {
        let context: TransactionEditorSession.Context
        let transaction: ActualTransaction
    }

    /// The budget a shared link is being resolved or waiting to open in.
    private var sharedLinkContext: TransactionEditorSession.Context?
    private var pendingSharedEdit: SharedEdit?
    private var sharedLinkTask: Task<Void, Never>?

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
        let context = TransactionEditorSession.Context(appState: appState)
        if let sharedLinkContext, sharedLinkContext != context { cancelSharedLink() }
        guard presentation?.context != context else { return }
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

    /// Starts a pending shared link once a budget is presented.
    func consumeSharedTransaction(using appState: AppState) {
        let coordinator = appState.routeCoordinator
        guard case .sharedTransaction(let id) = coordinator.pendingRoute,
              let context = TransactionEditorSession.Context(appState: appState) else { return }
        _ = coordinator.consume()
        let source = AppSharedTransactionLinkSource(appState: appState)
        sharedLinkTask?.cancel()
        sharedLinkTask = Task { [weak self] in
            await self?.openSharedTransaction(id: id, context: context, source: source) {
                TransactionEditorSession.Context(appState: appState)
            }
        }
    }

    func openSharedTransaction(
        id: String,
        context: TransactionEditorSession.Context,
        source: some SharedTransactionLinkSource,
        currentContext: () -> TransactionEditorSession.Context?
    ) async {
        sharedLinkContext = context
        pendingSharedEdit = nil
        guard let transaction = await sharedLinks.resolve(
            transactionID: id,
            budgetID: context.budgetID,
            source: source
        ), sharedLinkContext == context else { return }
        pendingSharedEdit = SharedEdit(context: context, transaction: transaction)
        presentPendingSharedEdit(currentContext: currentContext())
    }

    /// Opens a resolved link now, or once the editor already showing closes.
    @discardableResult
    func presentPendingSharedEdit(currentContext: TransactionEditorSession.Context?) -> Bool {
        guard let pending = pendingSharedEdit else { return false }
        guard currentContext == pending.context else {
            cancelSharedLink()
            return false
        }
        guard present(context: pending.context, request: .edit(pending.transaction)) else { return false }
        pendingSharedEdit = nil
        sharedLinkContext = nil
        return true
    }

    func cancelSharedLink() {
        sharedLinkTask?.cancel()
        sharedLinkTask = nil
        pendingSharedEdit = nil
        sharedLinkContext = nil
        sharedLinks.cancel()
    }
}
