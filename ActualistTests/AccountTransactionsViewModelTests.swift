import Foundation
import Testing
@testable import Actualist

@MainActor
struct AccountTransactionsViewModelTests {
    @Test func cachedSnapshotRendersImmediatelyAndSurvivesRefreshFailure() async {
        let cached = Self.loaded([Self.transaction(id: "cached", payee: "market")])
        let repository = AccountTransactionsRecordingRepository(
            accountSnapshot: cached,
            refreshError: FeedTestError("refresh failed")
        )
        let model = AccountTransactionsViewModel(scope: .account(Self.account))

        let firstFrame = model.displayState(
            budgetID: "budget",
            repository: repository,
            pendingNewTransactionIDs: ["cached"],
            privacyModeEnabled: false
        )
        #expect(firstFrame.groups.flatMap(\.rows).map(\.id) == ["cached"])
        #expect(firstFrame.groups.first?.rows.first?.isNew == true)

        await model.loadLocal(budgetID: "budget", repository: repository)

        #expect(!model.isLoading)
        #expect(model.errorMessage == nil)
        #expect(model.loadErrorMessage?.contains("Could not refresh all transactions") == true)
        #expect(model.displayState(budgetID: "budget", repository: repository,
                                   pendingNewTransactionIDs: [], privacyModeEnabled: false)
            .groups.flatMap(\.rows).map(\.id) == ["cached"])
        #expect(repository.refreshCalls == ["account:checking"])
    }

    @Test func firstLoadFailureWithoutCacheShowsError() async {
        let repository = AccountTransactionsRecordingRepository(
            refreshError: FeedTestError("could not load")
        )
        let model = AccountTransactionsViewModel(scope: .spending)

        await model.loadLocal(budgetID: "budget", repository: repository)

        #expect(!model.isLoading)
        #expect(model.loadErrorMessage?.contains("Could not load all transactions") == true)
        #expect(model.loadErrorMessage?.contains("could not load") == true)
    }

    @Test func emptyAndFailedFilterStatesStayScopedToTheSelectedFilter() async {
        let emptyRepository = AccountTransactionsRecordingRepository(
            accountSnapshot: Self.loaded([], reachedEnd: true)
        )
        let emptyModel = AccountTransactionsViewModel(scope: .account(Self.account))
        await emptyModel.selectFilter(.reconciled, budgetID: "budget", repository: emptyRepository)
        let empty = emptyModel.displayState(budgetID: "budget", repository: emptyRepository,
                                            pendingNewTransactionIDs: [], privacyModeEnabled: false)
        #expect(empty.statusFilter == .reconciled)
        #expect(empty.transactionCount == 0)
        #expect(empty.reachedEnd)
        #expect(empty.statusFilter.emptyMessage == "No reconciled transactions")

        let failingRepository = AccountTransactionsRecordingRepository(
            refreshError: FeedTestError("read failed")
        )
        let failingModel = AccountTransactionsViewModel(scope: .account(Self.account))
        await failingModel.selectFilter(.cleared, budgetID: "budget", repository: failingRepository)
        #expect(failingModel.loadErrorMessage?.contains("Could not load cleared transactions") == true)
        #expect(failingModel.loadErrorMessage?.contains("read failed") == true)
    }

    @Test func selectedFilterNeverFallsBackToAllRowsAndKeepsTheAllBalance() async {
        let allPage = Self.loaded([Self.transaction(id: "all-only")])
        let repository = AccountTransactionsRecordingRepository(
            accountSnapshot: allPage,
            filterSnapshots: [
                .all: allPage,
                .cleared: Self.loaded([], reachedEnd: true),
            ]
        )
        let model = AccountTransactionsViewModel(scope: .account(Self.account))
        let before = model.displayState(budgetID: "budget", repository: repository,
                                        pendingNewTransactionIDs: [], privacyModeEnabled: false)
        await model.selectFilter(.cleared, budgetID: "budget", repository: repository)
        let after = model.displayState(budgetID: "budget", repository: repository,
                                       pendingNewTransactionIDs: [], privacyModeEnabled: false)

        #expect(before.groups.flatMap(\.rows).map(\.id) == ["all-only"])
        #expect(after.groups.flatMap(\.rows).isEmpty)
        #expect(after.balanceText == before.balanceText)
    }

    @Test func loadingRoutesThroughEveryFeedScope() async {
        let repository = AccountTransactionsRecordingRepository()
        let categoryModel = AccountTransactionsViewModel(scope: .category(Self.categoryDetails))
        let accountModel = AccountTransactionsViewModel(scope: .account(Self.account))
        let spendingModel = AccountTransactionsViewModel(scope: .spending)

        await accountModel.loadLocal(budgetID: "budget", repository: repository)
        await spendingModel.loadLocal(budgetID: "budget", repository: repository)
        await categoryModel.loadLocal(budgetID: "budget", repository: repository)

        #expect(
            repository.refreshCalls == [
                "account:checking",
                "spending",
                "category:groceries:2026-08"
            ]
        )
    }

    @Test func paginationRejectsDuplicateRequestsWhileOneIsRunning() async {
        let repository = AccountTransactionsRecordingRepository(
            accountSnapshot: Self.loaded([Self.transaction(id: "first")], reachedEnd: false),
            suspendsOlderLoads: true
        )
        let model = AccountTransactionsViewModel(scope: .account(Self.account))
        await model.loadLocal(budgetID: "budget", repository: repository)

        let firstLoad = Task {
            await model.loadOlder(budgetID: "budget", repository: repository)
        }
        await repository.waitForOlderLoad()

        await model.loadOlder(budgetID: "budget", repository: repository)
        #expect(repository.olderLoadCalls == ["account:checking"])

        await repository.finishOlderLoad()
        await firstLoad.value
        #expect(!model.isLoadingOlder)
    }

    @Test func categorySearchFiltersTheCompleteLocalSnapshotWithoutRepositorySearch() async {
        let coffee = Self.transaction(id: "coffee", payee: "cafe", category: "dining")
        let fuel = Self.transaction(id: "fuel", payee: "station", category: "transport")
        let repository = AccountTransactionsRecordingRepository(
            categorySnapshot: Self.loaded(
                [coffee, fuel],
                categoryNames: ["dining": "Coffee Shops", "transport": "Fuel"]
            )
        )
        let model = AccountTransactionsViewModel(
            scope: .category(Self.categoryDetails),
            searchDelay: .zero
        )
        model.searchText = "coffee"

        model.scheduleSearch(budgetID: "budget", repository: repository)
        let display = model.displayState(
            budgetID: "budget",
            repository: repository,
            pendingNewTransactionIDs: [],
            privacyModeEnabled: false
        )

        #expect(!model.isSearching)
        #expect(display.groups.flatMap(\.rows).map(\.id) == ["coffee"])
        #expect(repository.searchQueries.isEmpty)
    }

    @Test func delayedSearchResultCannotReplaceTheNewerQuery() async {
        let repository = AccountTransactionsRecordingRepository(
            accountSnapshot: Self.loaded([Self.transaction(id: "cached")]),
            suspendsSearches: true
        )
        let model = AccountTransactionsViewModel(
            scope: .account(Self.account),
            searchDelay: .zero
        )

        model.searchText = "first"
        model.scheduleSearch(budgetID: "budget", repository: repository)
        await repository.waitForSearch("first|all|0")

        model.searchText = "second"
        model.scheduleSearch(budgetID: "budget", repository: repository)
        await repository.waitForSearch("second|all|0")

        await repository.finishSearch(
            "second",
            with: Self.loaded([Self.transaction(id: "second-result")])
        )
        await ObservedTestState { !model.isSearching }.wait()
        await repository.finishSearch(
            "first",
            with: Self.loaded([Self.transaction(id: "first-result")])
        )
        await Task.yield()

        let display = model.displayState(
            budgetID: "budget",
            repository: repository,
            pendingNewTransactionIDs: [],
            privacyModeEnabled: false
        )
        #expect(display.groups.flatMap(\.rows).map(\.id) == ["second-result"])
        #expect(model.searchText == "second")
    }

    @Test func filterChangeCancelsOldSearchAndSearchUsesSelectedFilter() async {
        let repository = AccountTransactionsRecordingRepository(suspendsSearches: true)
        let model = AccountTransactionsViewModel(scope: .account(Self.account), searchDelay: .zero)
        model.searchText = "market"
        model.scheduleSearch(budgetID: "budget", repository: repository)
        await repository.waitForSearch("market|all|0")

        await model.selectFilter(.cleared, budgetID: "budget", repository: repository)
        await repository.waitForSearch("market|cleared|0")
        await repository.finishSearch("market", filter: .cleared, with: Self.loaded([Self.transaction(id: "cleared")]))
        await ObservedTestState { !model.isSearching }.wait()
        await repository.finishSearch("market", filter: .all, with: Self.loaded([Self.transaction(id: "stale")]))
        await Task.yield()

        let state = model.displayState(budgetID: "budget", repository: repository,
                                       pendingNewTransactionIDs: [], privacyModeEnabled: false)
        #expect(model.statusFilter == .cleared)
        #expect(state.groups.flatMap(\.rows).map(\.id) == ["cleared"])
    }

    @Test func searchPaginationRequestsTheNextMatchOffset() async {
        let firstPage = Self.loaded((0..<50).map { Self.transaction(id: "match-\($0)") }, reachedEnd: false)
        let secondPage = Self.loaded([Self.transaction(id: "match-50")], reachedEnd: true)
        let repository = AccountTransactionsRecordingRepository(
            searchPages: ["market|all|0": firstPage, "market|all|50": secondPage]
        )
        let model = AccountTransactionsViewModel(scope: .spending, searchDelay: .zero)
        model.searchText = "market"
        model.scheduleSearch(budgetID: "budget", repository: repository)
        await repository.waitForSearch("market|all|0")
        await ObservedTestState { !model.isSearching }.wait()

        await model.loadOlder(budgetID: "budget", repository: repository)

        let state = model.displayState(budgetID: "budget", repository: repository,
                                       pendingNewTransactionIDs: [], privacyModeEnabled: false)
        #expect(repository.searchRequests == ["market|all|0", "market|all|50"])
        #expect(state.transactionCount == 51)
        #expect(state.reachedEnd)
    }

    @Test func filterResetReturnsToAllAndClearsSearchIdentity() async {
        let repository = AccountTransactionsRecordingRepository(
            accountSnapshot: Self.loaded([Self.transaction(id: "all")])
        )
        let model = AccountTransactionsViewModel(scope: .account(Self.account))
        await model.selectFilter(.reconciled, budgetID: "budget", repository: repository)
        model.searchText = "old query"
        model.scheduleSearch(budgetID: "budget", repository: repository)
        model.resetFeedSelection()

        #expect(model.statusFilter == .all)
        #expect(model.searchText.isEmpty)
    }

    @Test func clearingSearchPreservesTheSelectedFilter() async {
        let model = AccountTransactionsViewModel(scope: .spending)
        model.searchText = "market"
        model.scheduleSearch(budgetID: "budget", repository: AccountTransactionsRecordingRepository())
        await ObservedTestState { model.isSearching }.wait()
        await model.selectFilter(.reconciled, budgetID: "budget",
                                 repository: AccountTransactionsRecordingRepository())
        model.clearSearch(budgetID: "budget", repository: AccountTransactionsRecordingRepository())

        #expect(model.statusFilter == .reconciled)
        #expect(model.searchText.isEmpty)
        #expect(!model.isSearching)
    }

    @Test func newerBudgetSearchRejectsAnOlderBudgetCompletion() async {
        let repository = AccountTransactionsRecordingRepository(suspendsSearches: true)
        let model = AccountTransactionsViewModel(scope: .spending, searchDelay: .zero)
        model.searchText = "market"
        model.scheduleSearch(budgetID: "old-budget", repository: repository)
        await repository.waitForSearch("market|all|0", budgetID: "old-budget")
        await model.budgetDidChange(to: "new-budget", repository: repository)
        model.searchTextDidChange("market", budgetID: "new-budget", repository: repository)
        await repository.waitForSearch("market|all|0", budgetID: "new-budget")

        await repository.finishSearch("market", budgetID: "new-budget",
                                      with: Self.loaded([Self.transaction(id: "new-budget-result")]))
        await ObservedTestState { !model.isSearching }.wait()
        await repository.finishSearch("market", budgetID: "old-budget",
                                      with: Self.loaded([Self.transaction(id: "old-budget-result")]))
        await Task.yield()

        let state = model.displayState(budgetID: "new-budget", repository: repository,
                                       pendingNewTransactionIDs: [], privacyModeEnabled: false)
        #expect(state.groups.flatMap(\.rows).map(\.id) == ["new-budget-result"])
    }

    @Test func oldOlderLoadCompletionDoesNotKeepNewFilterBusy() async {
        let repository = AccountTransactionsRecordingRepository(
            accountSnapshot: Self.loaded([Self.transaction(id: "older-page")], reachedEnd: false),
            suspendsOlderLoads: true
        )
        let model = AccountTransactionsViewModel(scope: .account(Self.account))
        await model.loadLocal(budgetID: "budget", repository: repository)
        let olderLoad = Task { await model.loadOlder(budgetID: "budget", repository: repository) }
        await repository.waitForOlderLoad()

        await model.selectFilter(.cleared, budgetID: "budget", repository: repository)
        #expect(!model.isLoadingOlder)
        await repository.finishOlderLoad()
        await olderLoad.value

        #expect(model.statusFilter == .cleared)
        #expect(!model.isLoadingOlder)
    }

    @Test func refreshDuringSearchKeepsTheActiveSearchPage() async {
        let result = Self.loaded([Self.transaction(id: "searched")])
        let repository = AccountTransactionsRecordingRepository(
            accountSnapshot: Self.loaded([Self.transaction(id: "base")]),
            searchPages: ["market|all|0": result]
        )
        let model = AccountTransactionsViewModel(scope: .account(Self.account), searchDelay: .zero)
        model.searchText = "market"
        model.scheduleSearch(budgetID: "budget", repository: repository)
        await repository.waitForSearch("market|all|0")
        await ObservedTestState { !model.isSearching }.wait()

        await model.refresh(budgetID: "budget", repository: repository, sync: {}, onChanged: {})

        let state = model.displayState(budgetID: "budget", repository: repository,
                                       pendingNewTransactionIDs: [], privacyModeEnabled: false)
        #expect(state.groups.flatMap(\.rows).map(\.id) == ["searched"])
        #expect(model.searchErrorMessage == nil)
    }

    @Test func confirmedDeletePreservesFailureAndPublishesSuccess() async {
        let transaction = Self.transaction(id: "delete-me", payee: "market")
        let failingRepository = AccountTransactionsRecordingRepository(
            accountSnapshot: Self.loaded([transaction]),
            deleteError: FeedTestError("delete failed")
        )
        let model = AccountTransactionsViewModel(scope: .account(Self.account))

        await model.requestDelete(transaction, budgetID: "budget", repository: failingRepository)
        #expect(model.deletePresentation?.payeeName == "Market")
        #expect(model.deleteIntentFeedback == 1)

        await model.delete(
            transaction,
            budgetID: "budget",
            repository: failingRepository,
            onChanged: {}
        )
        #expect(model.errorMessage == "delete failed")
        #expect(model.deleteSuccessFeedback == 0)
        #expect(model.deletingTransactionID == nil)

        let successfulRepository = AccountTransactionsRecordingRepository(
            accountSnapshot: Self.loaded([transaction])
        )
        await model.delete(
            transaction,
            budgetID: "budget",
            repository: successfulRepository,
            onChanged: {}
        )
        #expect(model.errorMessage == nil)
        #expect(model.deleteSuccessFeedback == 1)
        #expect(successfulRepository.deletedTransactionIDs == ["delete-me"])
    }

    @Test func reconciledDeleteUsesPreparedWarningAndExactAuthorization() async {
        let transaction = Self.transaction(id: "locked", payee: "market")
        let review = ReconciledTransactionMutationReview(
            transactionID: "locked",
            targetReconciledTransactionIDs: ["locked"],
            pairedReconciledTransactionIDs: ["paired"]
        )
        let repository = AccountTransactionsRecordingRepository(
            accountSnapshot: Self.loaded([transaction]),
            reconciliationReview: review
        )
        let model = AccountTransactionsViewModel(scope: .account(Self.account))

        await model.requestDelete(transaction, budgetID: "budget", repository: repository)

        #expect(model.deletePresentation?.confirmationTitle == "Delete Reconciled Transaction?")
        #expect(model.deletePresentation?.message.contains("other side of its transfer") == true)
        let authorization = model.deletePresentation?.reconciliationAuthorization
        await model.delete(
            transaction,
            budgetID: "budget",
            repository: repository,
            reconciliationAuthorization: authorization,
            onChanged: {}
        )

        #expect(repository.deleteAuthorizations == [review.authorization])
        #expect(repository.deletedTransactionIDs == ["locked"])
    }

    static let account = ActualAccount(
        id: "checking",
        name: "Checking",
        offbudget: false,
        closed: false
    )

    static let categoryDetails = CategoryMonthDetails(
        category: BudgetMonthCategory(
            id: "groceries",
            name: "Groceries",
            isIncome: false,
            hidden: false,
            groupID: "usual",
            budgeted: 50_000,
            spent: -12_000,
            balance: 38_000,
            carryover: false
        ),
        month: "2026-08"
    )

    static func transaction(
        id: String,
        payee: String = "market",
        category: String? = nil
    ) -> ActualTransaction {
        ActualTransaction(
            id: id,
            account: "checking",
            date: "2026-08-20",
            amount: -1_200,
            payee: payee,
            payeeName: nil,
            importedPayee: nil,
            category: category,
            notes: nil,
            cleared: .bool(false)
        )
    }

    static func loaded(
        _ transactions: [ActualTransaction],
        categoryNames: [String: String] = [:],
        reachedEnd: Bool = true,
        nextOffset: Int? = nil
    ) -> LoadedAccountTransactions {
        LoadedAccountTransactions(
            transactions: transactions,
            balance: 12_345,
            accountNames: ["checking": "Checking"],
            categoryNames: categoryNames,
            payeeNames: ["market": "Market", "cafe": "Cafe", "station": "Station"],
            transferPayeeIDs: [],
            reachedEnd: reachedEnd,
            nextOffset: nextOffset
        )
    }
}

struct FeedTestError: Error, LocalizedError, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

@MainActor
final class AccountTransactionsRecordingRepository: TransactionRepositoryProtocol {
    let accountSnapshot: LoadedAccountTransactions?
    let spendingSnapshot: LoadedAccountTransactions?
    let categorySnapshot: LoadedAccountTransactions?
    private let refreshError: FeedTestError?
    private let deleteError: FeedTestError?
    private let suspendsOlderLoads: Bool
    private let suspendsSearches: Bool
    private let searchPages: [String: LoadedAccountTransactions]
    private let searchPagesByLimit: [String: LoadedAccountTransactions]
    private let searchErrorsByLimit: Set<String>
    private let filterSnapshots: [TransactionStatusFilter: LoadedAccountTransactions]?
    private let suspendsRefreshFilters: Set<TransactionStatusFilter>
    private let reconciliationReview: ReconciledTransactionMutationReview?

    private(set) var refreshCalls: [String] = []
    private(set) var olderLoadCalls: [String] = []
    private(set) var searchQueries: [String] = []
    private(set) var searchRequests: [String] = []
    private(set) var searchBudgetIDs: [String] = []
    private(set) var searchLimits: [Int] = []
    private(set) var refreshFilters: [TransactionStatusFilter] = []
    private(set) var deletedTransactionIDs: [String] = []
    private(set) var deleteAuthorizations: [ReconciledTransactionMutationAuthorization?] = []
    private var olderLoadContinuation: CheckedContinuation<Void, any Error>?
    private var searchContinuations: [String: CheckedContinuation<LoadedAccountTransactions, any Error>] = [:]
    private var refreshContinuations: [TransactionStatusFilter: CheckedContinuation<Void, any Error>] = [:]
    private let olderLoadStarted = TestLatch()
    private var searchStarted: [String: TestLatch] = [:]
    private var searchRequestCounts: [String: Int] = [:]
    private var refreshStarted: [TransactionStatusFilter: TestLatch] = [:]

    init(
        accountSnapshot: LoadedAccountTransactions? = nil,
        spendingSnapshot: LoadedAccountTransactions? = nil,
        categorySnapshot: LoadedAccountTransactions? = nil,
        refreshError: FeedTestError? = nil,
        deleteError: FeedTestError? = nil,
        suspendsOlderLoads: Bool = false,
        suspendsSearches: Bool = false,
        searchPages: [String: LoadedAccountTransactions] = [:],
        searchPagesByLimit: [String: LoadedAccountTransactions] = [:],
        searchErrorsByLimit: Set<String> = [],
        filterSnapshots: [TransactionStatusFilter: LoadedAccountTransactions]? = nil,
        suspendsRefreshFilters: Set<TransactionStatusFilter> = [],
        reconciliationReview: ReconciledTransactionMutationReview? = nil
    ) {
        self.accountSnapshot = accountSnapshot
        self.spendingSnapshot = spendingSnapshot
        self.categorySnapshot = categorySnapshot
        self.refreshError = refreshError
        self.deleteError = deleteError
        self.suspendsOlderLoads = suspendsOlderLoads
        self.suspendsSearches = suspendsSearches
        self.searchPages = searchPages
        self.searchPagesByLimit = searchPagesByLimit
        self.searchErrorsByLimit = searchErrorsByLimit
        self.filterSnapshots = filterSnapshots
        self.suspendsRefreshFilters = suspendsRefreshFilters
        self.reconciliationReview = reconciliationReview
    }

    func cachedAccountTransactions(
        budgetID: String,
        accountID: String,
        statusFilter: TransactionStatusFilter
    ) -> LoadedAccountTransactions? { filterSnapshots?[statusFilter] ?? (filterSnapshots == nil ? accountSnapshot : nil) }

    func cachedSpendingTransactions(
        budgetID: String,
        statusFilter: TransactionStatusFilter
    ) -> LoadedAccountTransactions? { filterSnapshots?[statusFilter] ?? (filterSnapshots == nil ? spendingSnapshot : nil) }

    func cachedCategoryTransactions(
        budgetID: String,
        categoryID: String,
        month: String
    ) -> LoadedAccountTransactions? { categorySnapshot }

    func refreshAccountTransactions(budgetID: String, accountID: String, statusFilter: TransactionStatusFilter) async throws {
        refreshCalls.append("account:\(accountID)")
        refreshFilters.append(statusFilter)
        refreshStarted[statusFilter]?.trip()
        if suspendsRefreshFilters.contains(statusFilter) {
            try await withCheckedThrowingContinuation { refreshContinuations[statusFilter] = $0 }
        }
        if let refreshError { throw refreshError }
    }

    func refreshSpendingTransactions(budgetID: String, statusFilter: TransactionStatusFilter) async throws {
        refreshCalls.append("spending")
        refreshFilters.append(statusFilter)
        refreshStarted[statusFilter]?.trip()
        if suspendsRefreshFilters.contains(statusFilter) {
            try await withCheckedThrowingContinuation { refreshContinuations[statusFilter] = $0 }
        }
        if let refreshError { throw refreshError }
    }

    func refreshCategoryTransactions(
        budgetID: String,
        categoryID: String,
        month: String
    ) async throws {
        refreshCalls.append("category:\(categoryID):\(month)")
        if let refreshError { throw refreshError }
    }

    func loadOlderTransactions(budgetID: String, accountID: String, statusFilter: TransactionStatusFilter) async throws {
        olderLoadCalls.append("account:\(accountID)")
        olderLoadStarted.trip()
        if suspendsOlderLoads {
            try await withCheckedThrowingContinuation { olderLoadContinuation = $0 }
        }
    }

    func loadOlderSpendingTransactions(budgetID: String, statusFilter: TransactionStatusFilter) async throws {
        olderLoadCalls.append("spending")
    }

    func finishOlderLoad() async {
        olderLoadContinuation?.resume()
        olderLoadContinuation = nil
    }

    func waitForOlderLoad() async {
        await olderLoadStarted.wait()
    }

    func waitForRefresh(_ filter: TransactionStatusFilter) async {
        if refreshFilters.contains(filter) { return }
        let latch = refreshStarted[filter] ?? TestLatch()
        refreshStarted[filter] = latch
        await latch.wait()
    }

    func waitForSearch(_ request: String, budgetID: String = "budget", occurrence: Int = 1) async {
        let identity = "\(budgetID)|\(request)"
        if searchRequestCounts[identity, default: 0] >= occurrence { return }
        let key = "\(identity)|\(occurrence)"
        let latch = searchStarted[key] ?? TestLatch()
        searchStarted[key] = latch
        await latch.wait()
    }

    func finishRefresh(_ filter: TransactionStatusFilter) async {
        refreshContinuations.removeValue(forKey: filter)?.resume()
    }

    func searchAccountTransactions(
        budgetID: String,
        accountID: String,
        query: String,
        limit: Int,
        offset: Int,
        statusFilter: TransactionStatusFilter
    ) async throws -> LoadedAccountTransactions {
        try await search(query, budgetID: budgetID, filter: statusFilter, limit: limit, offset: offset)
    }

    func searchSpendingTransactions(
        budgetID: String,
        query: String,
        limit: Int,
        offset: Int,
        statusFilter: TransactionStatusFilter
    ) async throws -> LoadedAccountTransactions {
        try await search(query, budgetID: budgetID, filter: statusFilter, limit: limit, offset: offset)
    }

    private func search(_ query: String, budgetID: String, filter: TransactionStatusFilter,
                        limit: Int, offset: Int) async throws -> LoadedAccountTransactions {
        searchQueries.append(query)
        searchBudgetIDs.append(budgetID)
        searchLimits.append(limit)
        let key = "\(query)|\(filter.rawValue)|\(offset)"
        searchRequests.append(key)
        let identity = "\(budgetID)|\(key)"
        let occurrence = searchRequestCounts[identity, default: 0] + 1
        searchRequestCounts[identity] = occurrence
        let startedKey = "\(identity)|\(occurrence)"
        searchStarted[startedKey]?.trip()
        let limitedKey = "\(key)|\(limit)"
        if searchErrorsByLimit.contains(limitedKey) { throw FeedTestError("search refresh failed") }
        if let page = searchPagesByLimit[limitedKey] { return page }
        if let page = searchPages[key] { return page }
        if suspendsSearches {
            return try await withCheckedThrowingContinuation {
                searchContinuations["\(budgetID)|\(key)"] = $0
            }
        }
        return LoadedAccountTransactions(
            transactions: [],
            balance: nil,
            categoryNames: [:],
            payeeNames: [:],
            transferPayeeIDs: [],
            reachedEnd: true
        )
    }

    func finishSearch(_ query: String, budgetID: String = "budget", filter: TransactionStatusFilter = .all,
                      offset: Int = 0, with loaded: LoadedAccountTransactions) async {
        let key = "\(budgetID)|\(query)|\(filter.rawValue)|\(offset)"
        searchContinuations.removeValue(forKey: key)?.resume(returning: loaded)
    }

    func editorOptions(budgetID: String, month: String) async throws -> TransactionEditorOptions {
        TransactionEditorOptions(accounts: [], categories: [], categoryGroups: [], payees: [])
    }

    func uncategorizedTransactions(
        budgetID: String,
        month: String
    ) async throws -> LoadedUncategorizedTransactions {
        LoadedUncategorizedTransactions(
            transactions: [],
            accountNames: [:],
            categoryNames: [:],
            payeeNames: [:],
            transferPayeeIDs: [],
            categoryGroups: []
        )
    }

    func previewRules(
        for draft: TransactionDraft,
        budgetID: String
    ) async throws -> TransactionRulePreview {
        TransactionRulePreview(categoryID: nil, notes: nil)
    }

    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
        didCreate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult { Self.emptyMutation }

    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult { Self.emptyMutation }

    func categorizeTransactionAndRefresh(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult { Self.emptyMutation }

    func categorizeTransactionsAndRefresh(
        _ transactions: [ActualTransaction],
        categoryID: String,
        budgetID: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult { Self.emptyMutation }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        didDelete: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        if let deleteError { throw deleteError }
        deletedTransactionIDs.append(transaction.rowID)
        await didDelete()
        return Self.emptyMutation
    }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        reconciliationAuthorization: ReconciledTransactionMutationAuthorization?,
        didDelete: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        deleteAuthorizations.append(reconciliationAuthorization)
        if let reconciliationReview,
           reconciliationAuthorization != reconciliationReview.authorization {
            throw ReconciledTransactionMutationError.confirmationRequired(reconciliationReview)
        }
        return try await deleteTransactionAndRefresh(
            transaction,
            budgetID: budgetID,
            didDelete: didDelete
        )
    }

    func reconciledMutationReview(
        budgetID: String,
        transactionID: String
    ) async throws -> ReconciledTransactionMutationReview? {
        reconciliationReview
    }

    private static let emptyMutation = TransactionMutationResult(
        ok: true,
        changed: ChangedResources(accounts: [], months: [], transactions: [])
    )
}
