import Foundation
import Observation

@MainActor
@Observable
final class TransactionFeedReadSession {
    struct Identity: Equatable {
        let budgetID: String
        let scope: TransactionQueryScope?
        let query: TransactionFeedQuery

        var statusFilter: TransactionStatusFilter { query.status }
        var searchText: String? { query.text }
    }

    enum Phase: Equatable {
        case idle
        case debouncing
        case loading
        case refreshing
        case loadingOlder
        case loaded
        case failed
        case cancelled
    }

    struct State {
        let identity: Identity?
        let requestID: UUID?
        let phase: Phase
        let searchPage: LoadedAccountTransactions?
        let errorMessage: String?
    }

    private(set) var query = TransactionFeedQuery.all
    private(set) var state = State(
        identity: nil,
        requestID: nil,
        phase: .idle,
        searchPage: nil,
        errorMessage: nil
    )

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private let searchDelay: Duration

    init(searchDelay: Duration = .milliseconds(250)) {
        self.searchDelay = searchDelay
    }

    var isLoading: Bool {
        state.searchPage == nil && (state.phase == .loading || state.phase == .debouncing)
    }
    var isLoadingOlder: Bool { state.phase == .loadingOlder }

    var statusFilter: TransactionStatusFilter { query.status }

    func identity(
        budgetID: String,
        scope: TransactionQueryScope?,
        query: TransactionFeedQuery
    ) -> Identity {
        Identity(budgetID: budgetID, scope: scope, query: query)
    }

    func acceptsBudget(_ budgetID: String) -> Bool {
        state.identity?.budgetID == nil || state.identity?.budgetID == budgetID
    }

    func select(_ filter: TransactionStatusFilter, identity: Identity) -> Identity? {
        guard statusFilter != filter else { return nil }
        activate(Identity(
            budgetID: identity.budgetID,
            scope: identity.scope,
            query: identity.query.replacingStatus(filter)
        ))
        return state.identity
    }

    func activate(_ identity: Identity) {
        guard state.identity != identity else { return }
        invalidateRequest()
        query = identity.query
        state = State(identity: identity, requestID: nil, phase: .idle,
                      searchPage: nil, errorMessage: nil)
    }

    func beginLocalRead(_ identity: Identity, hasCachedPage: Bool) -> UUID {
        activate(identity)
        let requestID = UUID()
        state = State(identity: identity, requestID: requestID,
                      phase: hasCachedPage ? .refreshing : .loading,
                      searchPage: nil, errorMessage: nil)
        return requestID
    }

    func beginOlderLocal(_ identity: Identity) -> UUID {
        invalidateRequest()
        let requestID = UUID()
        state = State(identity: identity, requestID: requestID, phase: .loadingOlder,
                      searchPage: nil, errorMessage: nil)
        return requestID
    }

    func beginSearch(_ identity: Identity, debounced: Bool) -> UUID {
        let retainedPage = state.identity == identity ? state.searchPage : nil
        invalidateRequest()
        let requestID = UUID()
        state = State(identity: identity, requestID: requestID,
                      phase: debounced ? .debouncing : retainedPage == nil ? .loading : .refreshing,
                      searchPage: retainedPage, errorMessage: nil)
        return requestID
    }

    func beginSearchRefresh(_ identity: Identity) -> UUID {
        let retainedPage = state.identity == identity ? state.searchPage : nil
        invalidateRequest()
        let requestID = UUID()
        state = State(identity: identity, requestID: requestID,
                      phase: retainedPage == nil ? .loading : .refreshing,
                      searchPage: retainedPage, errorMessage: nil)
        return requestID
    }

    func startSearch(
        _ identity: Identity,
        scope: TransactionFeedScope,
        repository: any TransactionRepositoryProtocol,
        debounced: Bool
    ) {
        guard identity.searchText != nil else { return }
        let requestID = beginSearch(identity, debounced: debounced)
        let task = Task { [weak self] in
            guard let self else { return }
            if debounced {
                do {
                    try await Task.sleep(for: searchDelay)
                } catch {
                    cancel(requestID, identity: identity)
                    return
                }
                guard promoteToLoading(requestID, identity: identity) else { return }
            }
            await performSearch(requestID, identity: identity, scope: scope, repository: repository)
        }
        searchTask = task
    }

    func refreshSearch(
        _ identity: Identity,
        scope: TransactionFeedScope,
        repository: any TransactionRepositoryProtocol
    ) async {
        guard identity.searchText != nil else { return }
        let requestID = beginSearchRefresh(identity)
        let task = Task { [weak self] in
            guard let self else { return }
            await performSearch(requestID, identity: identity, scope: scope, repository: repository)
        }
        searchTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func beginOlderSearch(_ identity: Identity) -> (UUID, LoadedAccountTransactions)? {
        guard state.identity == identity, (state.phase == .loaded || state.phase == .failed),
              let page = state.searchPage, !page.reachedEnd else { return nil }
        let requestID = UUID()
        state = State(identity: identity, requestID: requestID, phase: .loadingOlder,
                      searchPage: page, errorMessage: nil)
        return (requestID, page)
    }

    func loadOlderSearch(
        _ identity: Identity,
        scope: TransactionFeedScope,
        repository: any TransactionRepositoryProtocol
    ) async {
        guard identity.searchText != nil,
              let (requestID, page) = beginOlderSearch(identity) else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await performOlderSearch(requestID, identity: identity, page: page,
                                     scope: scope, repository: repository)
        }
        searchTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performOlderSearch(
        _ requestID: UUID,
        identity: Identity,
        page: LoadedAccountTransactions,
        scope: TransactionFeedScope,
        repository: any TransactionRepositoryProtocol
    ) async {
        do {
            guard let queryScope = scope.queryScope else { return }
            let older = try await repository.transactionPage(
                budgetID: identity.budgetID,
                scope: queryScope,
                query: identity.query,
                limit: 50,
                offset: page.nextOffset
            )
            finish(requestID, identity: identity, page: page.appendingPage(older))
        } catch {
            failOlderSearch(requestID, identity: identity, error: error)
        }
    }

    func finish(_ requestID: UUID, identity: Identity, page: LoadedAccountTransactions? = nil) {
        guard isCurrent(requestID, identity: identity), !Task.isCancelled else { return }
        state = State(identity: identity, requestID: nil, phase: .loaded,
                      searchPage: page ?? state.searchPage, errorMessage: nil)
        searchTask = nil
    }

    func fail(_ requestID: UUID, identity: Identity, error: any Error) {
        guard isCurrent(requestID, identity: identity) else { return }
        if error.isCancellation || Task.isCancelled {
            cancel(requestID, identity: identity)
            return
        }
        let action = state.phase == .refreshing ? "refresh" : "load"
        let description = identity.searchText == nil
            ? "\(identity.statusFilter.title.lowercased()) transactions"
            : "\(identity.statusFilter.title.lowercased()) search results"
        state = State(identity: identity, requestID: nil, phase: .failed,
                      searchPage: state.searchPage,
                      errorMessage: "Could not \(action) \(description). \(error.userFacingMessage ?? "")")
        searchTask = nil
    }

    func failOlderSearch(_ requestID: UUID, identity: Identity, error: any Error) {
        guard isCurrent(requestID, identity: identity) else { return }
        if error.isCancellation || Task.isCancelled {
            state = State(identity: identity, requestID: nil, phase: .loaded,
                          searchPage: state.searchPage, errorMessage: nil)
            searchTask = nil
            return
        }
        state = State(identity: identity, requestID: nil, phase: .failed,
                      searchPage: state.searchPage,
                      errorMessage: "Could not load older \(identity.statusFilter.title.lowercased()) transactions. \(error.userFacingMessage ?? "")")
        searchTask = nil
    }

    func page(for identity: Identity) -> LoadedAccountTransactions? {
        guard identity.searchText != nil, state.identity == identity else { return nil }
        return state.searchPage
    }

    func loadError(for identity: Identity) -> String? {
        guard state.identity == identity, state.phase == .failed else { return nil }
        return state.errorMessage
    }

    func isSearchLoading(_ identity: Identity) -> Bool {
        guard state.identity == identity, identity.searchText != nil else { return false }
        return state.searchPage == nil
            && (state.phase == .debouncing || state.phase == .loading)
    }

    func isCurrent(_ requestID: UUID, identity: Identity) -> Bool {
        state.requestID == requestID && state.identity == identity
    }

    private func promoteToLoading(_ requestID: UUID, identity: Identity) -> Bool {
        guard isCurrent(requestID, identity: identity) else { return false }
        state = State(identity: identity, requestID: requestID,
                      phase: state.searchPage == nil ? .loading : .refreshing,
                      searchPage: state.searchPage, errorMessage: nil)
        return true
    }

    func cancelCurrentRequest() {
        let current = state
        invalidateRequest()
        state = State(identity: current.identity, requestID: nil, phase: .cancelled,
                      searchPage: current.searchPage, errorMessage: nil)
    }

    private func cancel(_ requestID: UUID, identity: Identity) {
        guard isCurrent(requestID, identity: identity) else { return }
        state = State(identity: identity, requestID: nil, phase: .cancelled,
                      searchPage: state.searchPage, errorMessage: nil)
    }

    func cancelAndReset() {
        invalidateRequest()
        query = .all
        state = State(identity: nil, requestID: nil, phase: .idle,
                      searchPage: nil, errorMessage: nil)
    }

    func resetBudget(to budgetID: String, scope: TransactionQueryScope?) -> Identity {
        cancelAndReset()
        let identity = Identity(budgetID: budgetID, scope: scope, query: .all)
        state = State(identity: identity, requestID: nil, phase: .idle,
                      searchPage: nil, errorMessage: nil)
        return identity
    }

    private func invalidateRequest() {
        searchTask?.cancel()
        searchTask = nil
    }

    private func performSearch(
        _ requestID: UUID,
        identity: Identity,
        scope: TransactionFeedScope,
        repository: any TransactionRepositoryProtocol
    ) async {
        guard identity.searchText != nil else { return }
        let currentPage = state.identity == identity ? state.searchPage : nil
        do {
            guard let queryScope = scope.queryScope else { return }
            let loaded = try await repository.transactionPage(
                budgetID: identity.budgetID,
                scope: queryScope,
                query: identity.query,
                limit: max(currentPage?.nextOffset ?? 50, 50),
                offset: 0
            )
            finish(requestID, identity: identity, page: loaded)
        } catch {
            fail(requestID, identity: identity, error: error)
        }
    }
}
