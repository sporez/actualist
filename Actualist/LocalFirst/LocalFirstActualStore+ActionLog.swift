import Foundation

extension LocalFirstActualStore {
    /// Newest-first local money-flow gestures for the open budget. The rows
    /// live inside that budget's SQLite, so a budget switch or reimport never
    /// leaks another budget's history.
    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord] {
        let database = try requireDatabase(for: budgetID)
        return try await database.recentBudgetActions()
    }
}
