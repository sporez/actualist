import Foundation

/// Abstraction over the Actual HTTP API so the data layer can be exercised with a
/// fake client in tests. `ActualAPIClient` is the production implementation.
protocol ActualAPIClientProtocol: Sendable {
    func budgets() async throws -> [ActualBudget]
    func budgetMonth(budgetID: String, month: String) async throws -> BudgetMonth
    func budgetMonthAlerts(budgetID: String, month: String) async throws -> APIBudgetMonthAlerts
    func updateBudgetMonthCategory(
        budgetID: String,
        month: String,
        categoryID: String,
        budgeted: Int
    ) async throws -> APIGeneralResponseMessage
    func createCategoryTransfer(
        budgetID: String,
        month: String,
        fromCategoryID: String?,
        toCategoryID: String?,
        amount: Int
    ) async throws -> APIGeneralResponseMessage
    func applyBudgetTemplate(
        budgetID: String,
        month: String,
        command: BudgetTemplateCommand
    ) async throws -> APIBudgetTemplateApplyResult
    func budgetMonths(budgetID: String) async throws -> [String]
    func accounts(budgetID: String) async throws -> [ActualAccount]
    func createAccount(
        budgetID: String,
        name: String,
        offbudget: Bool
    ) async throws -> APIGeneralResponseMessage
    func balance(budgetID: String, accountID: String) async throws -> Int
    func syncBankAccount(
        budgetID: String,
        accountID: String
    ) async throws -> APIGeneralResponseMessage
    func reconcileAccount(
        budgetID: String,
        accountID: String,
        statementBalance: Int
    ) async throws -> APIAccountReconciliationResult
    func transactions(
        budgetID: String,
        accountID: String,
        since: Date,
        until: Date?
    ) async throws -> [ActualTransaction]
    func searchTransactions(
        budgetID: String,
        accountID: String,
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> [ActualTransaction]
    func payees(budgetID: String) async throws -> [ActualPayee]
    func categories(budgetID: String) async throws -> [ActualCategory]
    func createTransaction(
        budgetID: String,
        draft: TransactionDraft
    ) async throws -> APITransactionBatchUpdateResult
    func updateTransaction(
        budgetID: String,
        transactionID: String,
        draft: TransactionDraft
    ) async throws -> APITransactionBatchUpdateResult
    func deleteTransaction(
        budgetID: String,
        transaction: ActualTransaction
    ) async throws -> APITransactionBatchUpdateResult
    func runTransactionRules(
        budgetID: String,
        draft: TransactionDraft
    ) async throws -> TransactionRulePreview
}

extension ActualAPIClient: ActualAPIClientProtocol {}
