import Foundation

/// History: local money-flow gesture log and LIFO undo.
protocol BudgetHistoryRepositoryProtocol: Sendable {
    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord]
    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String]
    func budgetActionUndoPreview(actionID: String, budgetID: String) async throws -> BudgetActionUndoPreview
    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws
}
