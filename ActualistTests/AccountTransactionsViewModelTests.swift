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
        #expect(await repository.refreshCalls == ["account:checking"])
    }

    @Test func firstLoadFailureWithoutCacheShowsError() async {
        let repository = AccountTransactionsRecordingRepository(
            refreshError: FeedTestError("could not load")
        )
        let model = AccountTransactionsViewModel(scope: .spending)

        await model.loadLocal(budgetID: "budget", repository: repository)

        #expect(!model.isLoading)
        #expect(model.errorMessage == "could not load")
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
            await repository.refreshCalls == [
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
        await Self.waitUntil { await repository.olderLoadCalls == ["account:checking"] }

        await model.loadOlder(budgetID: "budget", repository: repository)
        #expect(await repository.olderLoadCalls == ["account:checking"])

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
        #expect(await repository.searchQueries.isEmpty)
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
        await Self.waitUntil { await repository.searchQueries.contains("first") }

        model.searchText = "second"
        model.scheduleSearch(budgetID: "budget", repository: repository)
        await Self.waitUntil { await repository.searchQueries.contains("second") }

        await repository.finishSearch(
            "second",
            with: Self.loaded([Self.transaction(id: "second-result")])
        )
        await Self.waitUntil { !model.isSearching }
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

    @Test func confirmedDeletePreservesFailureAndPublishesSuccess() async {
        let transaction = Self.transaction(id: "delete-me", payee: "market")
        let failingRepository = AccountTransactionsRecordingRepository(
            accountSnapshot: Self.loaded([transaction]),
            deleteError: FeedTestError("delete failed")
        )
        let model = AccountTransactionsViewModel(scope: .account(Self.account))

        model.requestDelete(transaction, budgetID: "budget", repository: failingRepository)
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
        #expect(await successfulRepository.deletedTransactionIDs == ["delete-me"])
    }

    private static let account = ActualAccount(
        id: "checking",
        name: "Checking",
        offbudget: false,
        closed: false
    )

    private static let categoryDetails = CategoryMonthDetails(
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

    private static func transaction(
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

    private static func loaded(
        _ transactions: [ActualTransaction],
        categoryNames: [String: String] = [:],
        reachedEnd: Bool = true
    ) -> LoadedAccountTransactions {
        LoadedAccountTransactions(
            transactions: transactions,
            balance: 12_345,
            accountNames: ["checking": "Checking"],
            categoryNames: categoryNames,
            payeeNames: ["market": "Market", "cafe": "Cafe", "station": "Station"],
            transferPayeeIDs: [],
            reachedEnd: reachedEnd
        )
    }

    private static func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for asynchronous test state")
    }
}

private struct FeedTestError: Error, LocalizedError, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private actor AccountTransactionsRecordingRepository: TransactionRepositoryProtocol {
    nonisolated let accountSnapshot: LoadedAccountTransactions?
    nonisolated let spendingSnapshot: LoadedAccountTransactions?
    nonisolated let categorySnapshot: LoadedAccountTransactions?
    private let refreshError: FeedTestError?
    private let deleteError: FeedTestError?
    private let suspendsOlderLoads: Bool
    private let suspendsSearches: Bool

    private(set) var refreshCalls: [String] = []
    private(set) var olderLoadCalls: [String] = []
    private(set) var searchQueries: [String] = []
    private(set) var deletedTransactionIDs: [String] = []
    private var olderLoadContinuation: CheckedContinuation<Void, any Error>?
    private var searchContinuations: [
        String: CheckedContinuation<LoadedAccountTransactions, any Error>
    ] = [:]

    init(
        accountSnapshot: LoadedAccountTransactions? = nil,
        spendingSnapshot: LoadedAccountTransactions? = nil,
        categorySnapshot: LoadedAccountTransactions? = nil,
        refreshError: FeedTestError? = nil,
        deleteError: FeedTestError? = nil,
        suspendsOlderLoads: Bool = false,
        suspendsSearches: Bool = false
    ) {
        self.accountSnapshot = accountSnapshot
        self.spendingSnapshot = spendingSnapshot
        self.categorySnapshot = categorySnapshot
        self.refreshError = refreshError
        self.deleteError = deleteError
        self.suspendsOlderLoads = suspendsOlderLoads
        self.suspendsSearches = suspendsSearches
    }

    nonisolated func cachedAccountTransactions(
        budgetID: String,
        accountID: String
    ) -> LoadedAccountTransactions? { accountSnapshot }

    nonisolated func cachedSpendingTransactions(
        budgetID: String
    ) -> LoadedAccountTransactions? { spendingSnapshot }

    nonisolated func cachedCategoryTransactions(
        budgetID: String,
        categoryID: String,
        month: String
    ) -> LoadedAccountTransactions? { categorySnapshot }

    func refreshAccountTransactions(budgetID: String, accountID: String) async throws {
        refreshCalls.append("account:\(accountID)")
        if let refreshError { throw refreshError }
    }

    func refreshSpendingTransactions(budgetID: String) async throws {
        refreshCalls.append("spending")
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

    func loadOlderTransactions(budgetID: String, accountID: String) async throws {
        olderLoadCalls.append("account:\(accountID)")
        if suspendsOlderLoads {
            try await withCheckedThrowingContinuation { olderLoadContinuation = $0 }
        }
    }

    func loadOlderSpendingTransactions(budgetID: String) async throws {
        olderLoadCalls.append("spending")
    }

    func finishOlderLoad() {
        olderLoadContinuation?.resume()
        olderLoadContinuation = nil
    }

    func searchAccountTransactions(
        budgetID: String,
        accountID: String,
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        try await search(query)
    }

    func searchSpendingTransactions(
        budgetID: String,
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        try await search(query)
    }

    private func search(_ query: String) async throws -> LoadedAccountTransactions {
        searchQueries.append(query)
        if suspendsSearches {
            return try await withCheckedThrowingContinuation { searchContinuations[query] = $0 }
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

    func finishSearch(_ query: String, with loaded: LoadedAccountTransactions) {
        searchContinuations.removeValue(forKey: query)?.resume(returning: loaded)
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
        didCreate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult { Self.emptyMutation }

    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult { Self.emptyMutation }

    func categorizeTransactionAndRefresh(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult { Self.emptyMutation }

    func categorizeTransactionsAndRefresh(
        _ transactions: [ActualTransaction],
        categoryID: String,
        budgetID: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult { Self.emptyMutation }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        didDelete: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        if let deleteError { throw deleteError }
        deletedTransactionIDs.append(transaction.rowID)
        await didDelete()
        return Self.emptyMutation
    }

    private static let emptyMutation = TransactionMutationResult(
        ok: true,
        changed: ChangedResources(accounts: [], months: [], transactions: [])
    )
}
