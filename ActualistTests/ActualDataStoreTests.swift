import Foundation
import Testing
@testable import Actualist

@MainActor
struct ActualDataStoreTests {
    @Test func accountsWithBalancesCachesAndComposesDisplays() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        try await store.refreshAccountsWithBalances(budgetID: "b")

        let displays = store.accountDisplays(budgetID: "b")
        #expect(displays.count == 2)
        #expect(displays.first(where: { $0.account.id == "checking" })?.balance == 1_000)
        #expect(displays.first(where: { $0.account.id == "savings" })?.balance == 5_000)
    }

    @Test func ensureReferenceDataServesCacheWithinTTL() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        try await store.ensureCategories(budgetID: "b")
        try await store.ensureCategories(budgetID: "b")

        #expect(await client.callCount(.categories) == 1)
    }

    @Test func concurrentRefreshesAreCoalescedIntoOneRequest() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        async let first: Void = store.refreshAccounts(budgetID: "b")
        async let second: Void = store.refreshAccounts(budgetID: "b")
        _ = try await (first, second)

        #expect(await client.callCount(.accounts) == 1)
    }

    @Test func refreshAccountTransactionsComposesCachedSnapshot() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        try await store.refreshAccountTransactions(budgetID: "b", accountID: "checking")

        let cached = try #require(store.cachedAccountTransactions(budgetID: "b", accountID: "checking"))
        #expect(cached.transactions.count == 1)
        #expect(cached.balance == 1_000)
        #expect(cached.categoryNames["groceries"] == "Groceries")
        #expect(cached.payeeNames["store"] == "Corner Store")
    }

    @Test func assignmentInvalidatesAndRefetchesAffectedMonth() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        // Warm the month cache.
        _ = try await store.budgetMonth(budgetID: "b", selectedMonth: "2026-06")
        let monthCallsAfterWarm = await client.callCount(.budgetMonth)

        let loaded = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 5_000,
            budgetID: "b",
            month: "2026-06",
            didAssign: {}
        )

        #expect(loaded.selectedMonth == "2026-06")
        #expect(await client.callCount(.updateBudgetMonthCategory) == 1)
        // The month was invalidated and refetched after the write.
        #expect(await client.callCount(.budgetMonth) > monthCallsAfterWarm)
    }

    @Test func createTransactionInvalidatesAffectedAccountAndMonth() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        let draft = TransactionDraft(
            accountID: "checking",
            date: Self.june2026,
            amountMinorUnits: -1_500,
            payeeID: "store",
            payeeName: "Corner Store",
            categoryID: "groceries",
            notes: nil,
            cleared: true
        )

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "b") {}

        #expect(result.ok)
        #expect(await client.callCount(.createTransaction) == 1)
        // Affected account transactions + month were refetched into the cache.
        #expect(store.cachedAccountTransactions(budgetID: "b", accountID: "checking") != nil)
        #expect(await client.callCount(.transactions) >= 1)
        #expect(await client.callCount(.budgetMonth) >= 1)
    }

    @Test func resetClearsAllCaches() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        try await store.refreshAccountTransactions(budgetID: "b", accountID: "checking")
        #expect(store.cachedAccountTransactions(budgetID: "b", accountID: "checking") != nil)

        store.reset()
        #expect(store.cachedAccountTransactions(budgetID: "b", accountID: "checking") == nil)
        #expect(store.accountDisplays(budgetID: "b").isEmpty)
    }

    private static var june2026: Date {
        DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 6, day: 15).date!
    }
}

actor FakeAPIClient: ActualAPIClientProtocol {
    enum Method {
        case accounts, balance, transactions, categories, payees, budgets
        case budgetMonths, budgetMonth, budgetMonthAlerts, updateBudgetMonthCategory
        case createTransaction, updateTransaction, deleteTransaction, runTransactionRules
    }

    private var counts: [Method: Int] = [:]

    func callCount(_ method: Method) -> Int {
        counts[method] ?? 0
    }

    private func record(_ method: Method) {
        counts[method, default: 0] += 1
    }

    func budgets() async throws -> [ActualBudget] {
        record(.budgets)
        return [ActualBudget(budgetID: "b", cloudFileId: nil, groupId: nil, name: "Budget", state: nil)]
    }

    func accounts(budgetID: String) async throws -> [ActualAccount] {
        record(.accounts)
        await Task.yield()
        return [
            ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false),
            ActualAccount(id: "savings", name: "Savings", offbudget: false, closed: false)
        ]
    }

    func balance(budgetID: String, accountID: String) async throws -> Int {
        record(.balance)
        return accountID == "checking" ? 1_000 : 5_000
    }

    func transactions(budgetID: String, accountID: String) async throws -> [ActualTransaction] {
        record(.transactions)
        return [
            ActualTransaction(
                id: "t1",
                account: accountID,
                date: "2026-06-15",
                amount: -1_500,
                payee: "store",
                payeeName: nil,
                importedPayee: nil,
                category: "groceries",
                notes: nil,
                cleared: .bool(true)
            )
        ]
    }

    func categories(budgetID: String) async throws -> [ActualCategory] {
        record(.categories)
        return [ActualCategory(id: "groceries", name: "Groceries", isIncome: false, hidden: false, groupID: "bills")]
    }

    func payees(budgetID: String) async throws -> [ActualPayee] {
        record(.payees)
        return [ActualPayee(id: "store", name: "Corner Store", category: nil, transferAccount: nil)]
    }

    func budgetMonths(budgetID: String) async throws -> [String] {
        record(.budgetMonths)
        return ["2026-05", "2026-06"]
    }

    func budgetMonth(budgetID: String, month: String) async throws -> BudgetMonth {
        record(.budgetMonth)
        return try JSONDecoder().decode(BudgetMonth.self, from: Self.budgetMonthJSON)
    }

    func budgetMonthAlerts(budgetID: String, month: String) async throws -> APIBudgetMonthAlerts {
        record(.budgetMonthAlerts)
        return APIBudgetMonthAlerts(month: month, alerts: [])
    }

    func updateBudgetMonthCategory(
        budgetID: String,
        month: String,
        categoryID: String,
        budgeted: Int
    ) async throws -> APIGeneralResponseMessage {
        record(.updateBudgetMonthCategory)
        return APIGeneralResponseMessage(message: "ok")
    }

    func createTransaction(budgetID: String, draft: TransactionDraft) async throws -> APITransactionBatchUpdateResult {
        record(.createTransaction)
        return try Self.emptyBatchResult()
    }

    func updateTransaction(
        budgetID: String,
        transactionID: String,
        draft: TransactionDraft
    ) async throws -> APITransactionBatchUpdateResult {
        record(.updateTransaction)
        return try Self.emptyBatchResult()
    }

    func deleteTransaction(
        budgetID: String,
        transaction: ActualTransaction
    ) async throws -> APITransactionBatchUpdateResult {
        record(.deleteTransaction)
        return try Self.emptyBatchResult()
    }

    func runTransactionRules(budgetID: String, draft: TransactionDraft) async throws -> TransactionRulePreview {
        record(.runTransactionRules)
        return TransactionRulePreview(categoryID: nil, notes: nil)
    }

    private static func emptyBatchResult() throws -> APITransactionBatchUpdateResult {
        try JSONDecoder().decode(APITransactionBatchUpdateResult.self, from: "{}".data(using: .utf8)!)
    }

    private static let budgetMonthJSON = """
    {
      "month": "2026-06",
      "incomeAvailable": 0,
      "lastMonthOverspent": 0,
      "forNextMonth": 0,
      "totalBudgeted": 0,
      "toBudget": 0,
      "fromLastMonth": 0,
      "totalIncome": 0,
      "totalSpent": 0,
      "totalBalance": 0,
      "categoryGroups": []
    }
    """.data(using: .utf8)!
}
