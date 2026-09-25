import Foundation
import Observation

@MainActor
@Observable
final class TransactionFeedReadSession {
    struct Identity: Equatable {
        let budgetID: String
        let statusFilter: TransactionStatusFilter
        let query: String?
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

    private(set) var statusFilter: TransactionStatusFilter = .all
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

    func identity(budgetID: String, query: String?) -> Identity {
        Identity(budgetID: budgetID, statusFilter: statusFilter, query: query)
    }

    func acceptsBudget(_ budgetID: String) -> Bool {
        state.identity?.budgetID == nil || state.identity?.budgetID == budgetID
    }

    func select(_ filter: TransactionStatusFilter, identity: Identity) -> Identity? {
        guard statusFilter != filter else { return nil }
        statusFilter = filter
        activate(Identity(budgetID: identity.budgetID, statusFilter: filter, query: identity.query))
        return state.identity
    }

    func activate(_ identity: Identity) {
        guard state.identity != identity else { return }
        invalidateRequest()
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
        guard identity.query != nil else { return }
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
        guard identity.query != nil else { return }
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
        guard let query = identity.query,
              let (requestID, page) = beginOlderSearch(identity) else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await performOlderSearch(requestID, identity: identity, query: query, page: page,
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
        query: String,
        page: LoadedAccountTransactions,
        scope: TransactionFeedScope,
        repository: any TransactionRepositoryProtocol
    ) async {
        do {
            let older: LoadedAccountTransactions
            switch scope {
            case .account(let account):
                older = try await repository.searchAccountTransactions(
                    budgetID: identity.budgetID, accountID: account.id, query: query,
                    limit: 50, offset: page.nextOffset, statusFilter: identity.statusFilter
                )
            case .spending:
                older = try await repository.searchSpendingTransactions(
                    budgetID: identity.budgetID, query: query, limit: 50,
                    offset: page.nextOffset, statusFilter: identity.statusFilter
                )
            case .category:
                return
            }
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
        let description = identity.query == nil
            ? "\(identity.statusFilter.title.lowercased()) transactions"
            : "\(identity.statusFilter.title.lowercased()) search results"
        state = State(identity: identity, requestID: nil, phase: .failed,
                      searchPage: state.searchPage,
                      errorMessage: "Could not \(action) \(description). \(error.userFacingMessage)")
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
                      errorMessage: "Could not load older \(identity.statusFilter.title.lowercased()) transactions. \(error.userFacingMessage)")
        searchTask = nil
    }

    func page(for identity: Identity) -> LoadedAccountTransactions? {
        guard identity.query != nil, state.identity == identity else { return nil }
        return state.searchPage
    }

    func loadError(for identity: Identity) -> String? {
        guard state.identity == identity, state.phase == .failed else { return nil }
        return state.errorMessage
    }

    func isSearchLoading(_ identity: Identity) -> Bool {
        guard state.identity == identity, identity.query != nil else { return false }
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
        statusFilter = .all
        state = State(identity: nil, requestID: nil, phase: .idle,
                      searchPage: nil, errorMessage: nil)
    }

    func resetBudget(to budgetID: String) -> Identity {
        cancelAndReset()
        let identity = Identity(budgetID: budgetID, statusFilter: .all, query: nil)
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
        guard let query = identity.query else { return }
        let currentPage = state.identity == identity ? state.searchPage : nil
        do {
            let loaded: LoadedAccountTransactions
            switch scope {
            case .account(let account):
                loaded = try await repository.searchAccountTransactions(
                    budgetID: identity.budgetID, accountID: account.id, query: query,
                    limit: max(currentPage?.nextOffset ?? 50, 50), offset: 0,
                    statusFilter: identity.statusFilter
                )
            case .spending:
                loaded = try await repository.searchSpendingTransactions(
                    budgetID: identity.budgetID, query: query,
                    limit: max(currentPage?.nextOffset ?? 50, 50), offset: 0,
                    statusFilter: identity.statusFilter
                )
            case .category:
                return
            }
            finish(requestID, identity: identity, page: loaded)
        } catch {
            fail(requestID, identity: identity, error: error)
        }
    }
}
