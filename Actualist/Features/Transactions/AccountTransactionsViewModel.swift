import Foundation
import Observation

@MainActor
@Observable
final class AccountTransactionsViewModel {
    let scope: TransactionFeedScope

    var isLoading: Bool { readSession.isLoading || deletingTransactionID != nil }
    var searchText = ""
    private let readSession: TransactionFeedReadSession
    var isLoadingOlder: Bool { readSession.isLoadingOlder }
    var isSearching: Bool {
        readSession.state.identity?.query != nil
            && (readSession.state.phase == .debouncing || readSession.state.phase == .loading)
    }
    func isSearchLoading(budgetID: String?) -> Bool {
        guard !scope.isCategory, let identity = readIdentity(budgetID: budgetID) else { return false }
        return readSession.isSearchLoading(identity)
    }
    var searchErrorMessage: String? {
        guard let identity = readSession.state.identity, identity.query != nil else { return nil }
        return readSession.loadError(for: identity)
    }
    var loadErrorMessage: String? {
        guard let identity = readSession.state.identity, identity.query == nil else { return nil }
        return readSession.loadError(for: identity)
    }
    private(set) var errorMessage: String?
    var deletePresentation: TransactionDeletePresentation?
    private(set) var deletingTransactionID: String?
    private(set) var deleteIntentFeedback = 0
    private(set) var deleteSuccessFeedback = 0

    @ObservationIgnored private var deleteRequestGeneration = 0

    init(
        scope: TransactionFeedScope,
        searchDelay: Duration = .milliseconds(250)
    ) {
        self.scope = scope
        self.readSession = TransactionFeedReadSession(searchDelay: searchDelay)
    }

    var statusFilter: TransactionStatusFilter { readSession.statusFilter }

    func selectFilter(_ filter: TransactionStatusFilter, budgetID: String?,
                      repository: any TransactionRepositoryProtocol) async {
        guard let budgetID, readSession.acceptsBudget(budgetID) else { return }
        let query = scope.isCategory ? nil : activeQuery
        let identity = TransactionFeedReadSession.Identity(
            budgetID: budgetID, statusFilter: filter, query: query
        )
        guard let selected = readSession.select(filter, identity: identity) else { return }
        errorMessage = nil
        if selected.query != nil {
            readSession.startSearch(selected, scope: scope, repository: repository, debounced: false)
        } else {
            await loadLocal(selected, repository: repository)
        }
    }

    func resetFeedSelection() {
        readSession.cancelAndReset()
        searchText = ""
    }

    var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSearchActive: Bool {
        !trimmedSearchText.isEmpty
    }

    private var activeQuery: String? {
        guard isSearchActive, !scope.isCategory else { return nil }
        return trimmedSearchText
    }

    private func readIdentity(budgetID: String?) -> TransactionFeedReadSession.Identity? {
        guard let budgetID else { return nil }
        return readSession.identity(budgetID: budgetID, query: activeQuery)
    }

    func displayState(
        budgetID: String?,
        repository: any TransactionRepositoryProtocol,
        pendingNewTransactionIDs: Set<String>,
        privacyModeEnabled: Bool,
        currency: BudgetCurrency = .usd
    ) -> AccountTransactionsDisplayState {
        projection(
            budgetID: budgetID,
            repository: repository,
            pendingNewTransactionIDs: pendingNewTransactionIDs,
            privacyModeEnabled: privacyModeEnabled,
            currency: currency
        ).displayState
    }

    func showCreateEditor(using appState: AppState, presenter: RootTransactionEditorPresenter) {
        presenter.present(using: appState, account: scope.account, categoryName: scope.prefilledCategoryName)
    }

    func showEditor(for transaction: ActualTransaction, using appState: AppState, presenter: RootTransactionEditorPresenter) {
        let request = projection(
            budgetID: appState.settings.selectedBudgetID,
            repository: appState.transactionRepository
        ).editorPresentation(for: transaction)
        presenter.present(using: appState, request: request, account: scope.account, categoryName: scope.prefilledCategoryName)
    }

    func requestDelete(
        _ transaction: ActualTransaction,
        budgetID: String?,
        repository: any TransactionRepositoryProtocol
    ) async {
        guard let transactionID = transaction.id else {
            errorMessage = "This transaction cannot be deleted because it is missing its transaction ID."
            return
        }

        deleteIntentFeedback += 1
        deleteRequestGeneration &+= 1
        let requestGeneration = deleteRequestGeneration
        do {
            let review: ReconciledTransactionMutationReview? = if let budgetID {
                try await repository.reconciledMutationReview(
                    budgetID: budgetID,
                    transactionID: transactionID
                )
            } else {
                nil
            }
            guard requestGeneration == deleteRequestGeneration else { return }
            deletePresentation = projection(
                budgetID: budgetID,
                repository: repository
            ).deletePresentation(for: transaction, reconciliationReview: review)
            errorMessage = nil
        } catch {
            guard requestGeneration == deleteRequestGeneration else { return }
            errorMessage = error.userFacingMessage
        }
    }

    func delete(
        _ transaction: ActualTransaction,
        budgetID: String?,
        repository: any TransactionRepositoryProtocol,
        reconciliationAuthorization: ReconciledTransactionMutationAuthorization? = nil,
        onChanged: @MainActor () -> Void
    ) async {
        guard let budgetID, deletingTransactionID == nil else {
            return
        }

        deletingTransactionID = transaction.rowID
        errorMessage = nil
        defer {
            deletingTransactionID = nil
        }

        do {
            _ = try await repository.deleteTransactionAndRefresh(
                transaction,
                budgetID: budgetID,
                reconciliationAuthorization: reconciliationAuthorization
            ) {}
            if case .category(let details) = scope {
                try await repository.refreshCategoryTransactions(
                    budgetID: budgetID,
                    categoryID: details.category.id,
                    month: details.month
                )
                onChanged()
            }
            deleteSuccessFeedback += 1
            deletePresentation = nil
        } catch {
            if case .confirmationRequired(let review) = error as? ReconciledTransactionMutationError {
                deletePresentation = projection(
                    budgetID: budgetID,
                    repository: repository
                ).deletePresentation(for: transaction, reconciliationReview: review)
                errorMessage = nil
            } else {
                errorMessage = error.userFacingMessage
            }
        }
    }

    func loadLocal(
        budgetID: String?,
        repository: any TransactionRepositoryProtocol
    ) async {
        guard let budgetID, readSession.acceptsBudget(budgetID),
              let identity = readIdentity(budgetID: budgetID) else { return }
        if identity.query != nil {
            await readSession.refreshSearch(identity, scope: scope, repository: repository)
        } else {
            await loadLocal(identity, repository: repository)
        }
    }

    private func loadLocal(
        _ identity: TransactionFeedReadSession.Identity,
        repository: any TransactionRepositoryProtocol
    ) async {
        guard readSession.acceptsBudget(identity.budgetID) else { return }
        let hadLoadedSnapshot = cachedSnapshot(identity, repository: repository) != nil
        errorMessage = nil
        let requestID = readSession.beginLocalRead(identity, hasCachedPage: hadLoadedSnapshot)

        do {
            try await refreshSnapshot(identity, repository: repository)
            readSession.finish(requestID, identity: identity)
        } catch {
            readSession.fail(requestID, identity: identity, error: error)
        }
    }

    func refresh(
        budgetID: String?,
        repository: any TransactionRepositoryProtocol,
        sync: @MainActor () async -> Void,
        onChanged: @MainActor () -> Void
    ) async {
        guard budgetID != nil else {
            return
        }
        await sync()
        guard let budgetID, readSession.acceptsBudget(budgetID) else { return }
        await refreshCurrentData(budgetID: budgetID, repository: repository)
        onChanged()
    }

    func localDataDidChange(budgetID: String?, repository: any TransactionRepositoryProtocol) async {
        guard let budgetID, readSession.acceptsBudget(budgetID) else { return }
        await refreshCurrentData(budgetID: budgetID, repository: repository)
    }

    func budgetDidChange(to budgetID: String?, repository: any TransactionRepositoryProtocol) async {
        guard let budgetID else {
            resetFeedSelection()
            return
        }
        searchText = ""
        let identity = readSession.resetBudget(to: budgetID)
        errorMessage = nil
        await loadLocal(identity, repository: repository)
    }

    func feedDidDisappear(editorIsPresented: Bool) {
        if editorIsPresented {
            readSession.cancelCurrentRequest()
        } else {
            resetFeedSelection()
        }
    }

    func editorPresentationChanged(
        editorDismissed: Bool,
        budgetID: String?,
        repository: any TransactionRepositoryProtocol
    ) {
        guard editorDismissed, let budgetID, readSession.acceptsBudget(budgetID),
              let identity = readIdentity(budgetID: budgetID),
              readSession.state.phase == .cancelled else { return }
        if identity.query != nil {
            readSession.startSearch(identity, scope: scope, repository: repository, debounced: false)
        } else {
            Task { await loadLocal(identity, repository: repository) }
        }
    }

    func searchTextDidChange(_ value: String, budgetID: String?, repository: any TransactionRepositoryProtocol) {
        guard let budgetID, readSession.acceptsBudget(budgetID) else { return }
        searchText = value
        guard let identity = readIdentity(budgetID: budgetID) else { return }
        readSession.activate(identity)
        if identity.query != nil {
            readSession.startSearch(identity, scope: scope, repository: repository, debounced: true)
        } else if cachedSnapshot(identity, repository: repository) == nil {
            Task { await loadLocal(identity, repository: repository) }
        }
    }

    private func refreshCurrentData(budgetID: String?, repository: any TransactionRepositoryProtocol) async {
        guard let budgetID, readSession.acceptsBudget(budgetID),
              let identity = readIdentity(budgetID: budgetID) else { return }
        if identity.query != nil {
            await readSession.refreshSearch(identity, scope: scope, repository: repository)
        } else {
            await loadLocal(identity, repository: repository)
        }
    }

    func loadOlder(
        budgetID: String?,
        repository: any TransactionRepositoryProtocol
    ) async {
        guard let budgetID, readSession.acceptsBudget(budgetID),
              let identity = readIdentity(budgetID: budgetID),
              let loaded = activeCachedSnapshot(identity, repository: repository),
              !loaded.reachedEnd,
              !isLoadingOlder else {
            return
        }

        if identity.query != nil {
            await readSession.loadOlderSearch(identity, scope: scope, repository: repository)
            return
        }
        guard !isLoading else { return }
        let requestID = readSession.beginOlderLocal(identity)

        do {
            switch scope {
            case .account(let account):
                try await repository.loadOlderTransactions(budgetID: identity.budgetID, accountID: account.id,
                                                           statusFilter: identity.statusFilter)
            case .spending:
                try await repository.loadOlderSpendingTransactions(budgetID: identity.budgetID,
                                                                  statusFilter: identity.statusFilter)
            case .category:
                return
            }
            readSession.finish(requestID, identity: identity)
        } catch {
            readSession.fail(requestID, identity: identity, error: error)
        }
    }

    func scheduleSearch(
        budgetID: String?,
        repository: any TransactionRepositoryProtocol
    ) {
        guard let budgetID, readSession.acceptsBudget(budgetID),
              let identity = readIdentity(budgetID: budgetID), identity.query != nil else { return }
        readSession.startSearch(identity, scope: scope, repository: repository, debounced: true)
    }

    func clearSearch(budgetID: String?, repository: any TransactionRepositoryProtocol) {
        guard let budgetID, readSession.acceptsBudget(budgetID) else {
            searchText = ""
            readSession.cancelCurrentRequest()
            return
        }
        searchText = ""
        guard let identity = readIdentity(budgetID: budgetID) else { return }
        readSession.activate(identity)
        if cachedSnapshot(identity, repository: repository) == nil {
            Task { await loadLocal(identity, repository: repository) }
        }
    }

    func retrySearch(budgetID: String?, repository: any TransactionRepositoryProtocol) {
        guard let budgetID, readSession.acceptsBudget(budgetID),
              let identity = readIdentity(budgetID: budgetID), identity.query != nil else { return }
        readSession.startSearch(identity, scope: scope, repository: repository, debounced: false)
    }

    func clearPendingNewTransactions(
        budgetID: String?,
        clear: @MainActor (_ budgetID: String, _ accountID: String?) -> Void
    ) {
        guard let budgetID else { return }
        clear(budgetID, scope.account?.id)
    }

    private func refreshSnapshot(
        _ identity: TransactionFeedReadSession.Identity,
        repository: any TransactionRepositoryProtocol
    ) async throws {
        switch scope {
        case .account(let account):
            try await repository.refreshAccountTransactions(
                budgetID: identity.budgetID, accountID: account.id, statusFilter: identity.statusFilter
            )
        case .spending:
            try await repository.refreshSpendingTransactions(
                budgetID: identity.budgetID, statusFilter: identity.statusFilter
            )
        case .category(let details):
            try await repository.refreshCategoryTransactions(
                budgetID: identity.budgetID, categoryID: details.category.id, month: details.month
            )
        }
    }

    private func cachedSnapshot(
        _ identity: TransactionFeedReadSession.Identity,
        repository: any TransactionRepositoryProtocol
    ) -> LoadedAccountTransactions? {
        switch scope {
        case .account(let account):
            return repository.cachedAccountTransactions(
                budgetID: identity.budgetID, accountID: account.id, statusFilter: identity.statusFilter
            )
        case .spending:
            return repository.cachedSpendingTransactions(
                budgetID: identity.budgetID, statusFilter: identity.statusFilter
            )
        case .category(let details):
            return repository.cachedCategoryTransactions(
                budgetID: identity.budgetID,
                categoryID: details.category.id,
                month: details.month
            )
        }
    }

    private func unfilteredSnapshot(
        budgetID: String?, repository: any TransactionRepositoryProtocol
    ) -> LoadedAccountTransactions? {
        guard let budgetID else { return nil }
        switch scope {
        case .account(let account):
            return repository.cachedAccountTransactions(budgetID: budgetID, accountID: account.id,
                                                        statusFilter: .all)
        case .spending:
            return repository.cachedSpendingTransactions(budgetID: budgetID, statusFilter: .all)
        case .category(let details):
            return repository.cachedCategoryTransactions(budgetID: budgetID,
                categoryID: details.category.id, month: details.month)
        }
    }

    private func activeCachedSnapshot(
        _ identity: TransactionFeedReadSession.Identity,
        repository: any TransactionRepositoryProtocol
    ) -> LoadedAccountTransactions? {
        if identity.query != nil {
            return readSession.page(for: identity)
        }
        return cachedSnapshot(identity, repository: repository)
    }

    private func projection(
        budgetID: String?,
        repository: any TransactionRepositoryProtocol,
        pendingNewTransactionIDs: Set<String> = [],
        privacyModeEnabled: Bool = false,
        currency: BudgetCurrency = .usd
    ) -> AccountTransactionFeedProjection {
        AccountTransactionFeedProjection(
            scope: scope,
            loaded: unfilteredSnapshot(budgetID: budgetID, repository: repository),
            activePage: readIdentity(budgetID: budgetID).flatMap {
                activeCachedSnapshot($0, repository: repository)
            },
            statusFilter: readSession.statusFilter,
            query: trimmedSearchText,
            pendingNewTransactionIDs: pendingNewTransactionIDs,
            privacyModeEnabled: privacyModeEnabled,
            currency: currency
        )
    }

}

private extension TransactionFeedScope {
    var isCategory: Bool {
        if case .category = self { return true }
        return false
    }
}
