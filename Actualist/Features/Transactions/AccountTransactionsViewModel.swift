import Foundation
import Observation

@MainActor
@Observable
final class AccountTransactionsViewModel {
    let scope: TransactionFeedScope

    var isLoading = true
    var isLoadingOlder = false
    var searchText = ""
    private(set) var isSearching = false
    private(set) var searchErrorMessage: String?
    var errorMessage: String?
    var transactionEditorPresentation: TransactionEditorPresentation?
    var deletePresentation: TransactionDeletePresentation?
    private(set) var deletingTransactionID: String?
    private(set) var deleteIntentFeedback = 0
    private(set) var deleteSuccessFeedback = 0

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private let searchDelay: Duration
    private var searchResult: SearchResult?

    init(
        scope: TransactionFeedScope,
        searchDelay: Duration = .milliseconds(250)
    ) {
        self.scope = scope
        self.searchDelay = searchDelay
    }

    var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSearchActive: Bool {
        !trimmedSearchText.isEmpty
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

    func showCreateEditor() {
        transactionEditorPresentation = .create
    }

    func showEditor(
        for transaction: ActualTransaction,
        budgetID: String?,
        repository: any TransactionRepositoryProtocol
    ) {
        transactionEditorPresentation = projection(
            budgetID: budgetID,
            repository: repository
        ).editorPresentation(for: transaction)
    }

    func requestDelete(
        _ transaction: ActualTransaction,
        budgetID: String?,
        repository: any TransactionRepositoryProtocol
    ) {
        guard transaction.id != nil else {
            errorMessage = "This transaction cannot be deleted because it is missing its transaction ID."
            return
        }

        deleteIntentFeedback += 1
        deletePresentation = projection(
            budgetID: budgetID,
            repository: repository
        ).deletePresentation(for: transaction)
    }

    func delete(
        _ transaction: ActualTransaction,
        budgetID: String?,
        repository: any TransactionRepositoryProtocol,
        onChanged: @MainActor () -> Void
    ) async {
        guard let budgetID, deletingTransactionID == nil else {
            return
        }

        deletingTransactionID = transaction.rowID
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            deletingTransactionID = nil
        }

        do {
            _ = try await repository.deleteTransactionAndRefresh(
                transaction,
                budgetID: budgetID
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadLocal(
        budgetID: String?,
        repository: any TransactionRepositoryProtocol
    ) async {
        guard let budgetID else {
            isLoading = false
            return
        }

        let hadLoadedSnapshot = cachedSnapshot(budgetID: budgetID, repository: repository) != nil
        isLoading = !hadLoadedSnapshot
        errorMessage = nil

        do {
            try await refreshSnapshot(budgetID: budgetID, repository: repository)
        } catch {
            if cachedSnapshot(budgetID: budgetID, repository: repository) == nil {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
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
        await loadLocal(budgetID: budgetID, repository: repository)
        onChanged()
    }

    func loadOlder(
        budgetID: String?,
        repository: any TransactionRepositoryProtocol
    ) async {
        guard let budgetID,
              let loaded = cachedSnapshot(budgetID: budgetID, repository: repository),
              !loaded.reachedEnd,
              !isLoading,
              !isLoadingOlder else {
            return
        }

        isLoadingOlder = true
        errorMessage = nil
        defer { isLoadingOlder = false }

        do {
            switch scope {
            case .account(let account):
                try await repository.loadOlderTransactions(budgetID: budgetID, accountID: account.id)
            case .spending:
                try await repository.loadOlderSpendingTransactions(budgetID: budgetID)
            case .category:
                return
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scheduleSearch(
        budgetID: String?,
        repository: any TransactionRepositoryProtocol
    ) {
        searchTask?.cancel()
        searchGeneration += 1
        searchResult = nil
        searchErrorMessage = nil

        let query = trimmedSearchText
        guard let budgetID, !query.isEmpty else {
            isSearching = false
            return
        }
        guard !scope.isCategory else {
            isSearching = false
            return
        }

        let request = SearchRequest(
            generation: searchGeneration,
            budgetID: budgetID,
            query: query
        )
        isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: searchDelay)
            } catch {
                return
            }
            await performSearch(request, repository: repository)
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchGeneration += 1
        searchText = ""
        searchResult = nil
        searchErrorMessage = nil
        isSearching = false
    }

    func cancelSearch() {
        searchTask?.cancel()
        isSearching = false
    }

    func clearPendingNewTransactions(
        budgetID: String?,
        clear: @MainActor (_ budgetID: String, _ accountID: String?) -> Void
    ) {
        guard let budgetID else { return }
        clear(budgetID, scope.account?.id)
    }

    private func refreshSnapshot(
        budgetID: String,
        repository: any TransactionRepositoryProtocol
    ) async throws {
        switch scope {
        case .account(let account):
            try await repository.refreshAccountTransactions(budgetID: budgetID, accountID: account.id)
        case .spending:
            try await repository.refreshSpendingTransactions(budgetID: budgetID)
        case .category(let details):
            try await repository.refreshCategoryTransactions(
                budgetID: budgetID,
                categoryID: details.category.id,
                month: details.month
            )
        }
    }

    private func performSearch(
        _ request: SearchRequest,
        repository: any TransactionRepositoryProtocol
    ) async {
        do {
            let loaded: LoadedAccountTransactions
            switch scope {
            case .account(let account):
                loaded = try await repository.searchAccountTransactions(
                    budgetID: request.budgetID,
                    accountID: account.id,
                    query: request.query,
                    limit: 50,
                    offset: 0
                )
            case .spending:
                loaded = try await repository.searchSpendingTransactions(
                    budgetID: request.budgetID,
                    query: request.query,
                    limit: 50,
                    offset: 0
                )
            case .category:
                return
            }
            guard isCurrent(request), !Task.isCancelled else { return }
            searchResult = SearchResult(request: request, loaded: loaded)
            isSearching = false
        } catch {
            guard isCurrent(request), !Task.isCancelled else { return }
            searchErrorMessage = error.localizedDescription
            isSearching = false
        }
    }

    private func isCurrent(_ request: SearchRequest) -> Bool {
        request.generation == searchGeneration && request.query == trimmedSearchText
    }

    private func matchingSearchResult(budgetID: String?) -> SearchResult? {
        guard let result = searchResult,
              result.request.budgetID == budgetID,
              result.request.query == trimmedSearchText else {
            return nil
        }
        return result
    }

    private func cachedSnapshot(
        budgetID: String?,
        repository: any TransactionRepositoryProtocol
    ) -> LoadedAccountTransactions? {
        guard let budgetID else { return nil }
        switch scope {
        case .account(let account):
            return repository.cachedAccountTransactions(budgetID: budgetID, accountID: account.id)
        case .spending:
            return repository.cachedSpendingTransactions(budgetID: budgetID)
        case .category(let details):
            return repository.cachedCategoryTransactions(
                budgetID: budgetID,
                categoryID: details.category.id,
                month: details.month
            )
        }
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
            loaded: cachedSnapshot(budgetID: budgetID, repository: repository),
            searchLoaded: matchingSearchResult(budgetID: budgetID)?.loaded,
            query: trimmedSearchText,
            pendingNewTransactionIDs: pendingNewTransactionIDs,
            privacyModeEnabled: privacyModeEnabled,
            currency: currency
        )
    }

    private struct SearchRequest: Hashable {
        let generation: Int
        let budgetID: String
        let query: String
    }

    private struct SearchResult {
        let request: SearchRequest
        let loaded: LoadedAccountTransactions
    }
}

private extension TransactionFeedScope {
    var isCategory: Bool {
        if case .category = self { return true }
        return false
    }
}
