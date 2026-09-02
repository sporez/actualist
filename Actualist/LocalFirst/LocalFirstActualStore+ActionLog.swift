import Foundation

extension LocalFirstActualStore {
    /// Newest-first local money-flow gestures for the open budget. The rows
    /// live inside that budget's SQLite, so a budget switch or reimport never
    /// leaks another budget's history.
    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord] {
        let database = try requireDatabase(for: budgetID)
        return try await database.recentBudgetActions()
    }

    /// Live and historical category names for History rows. Deleted categories
    /// simply have no entry; the view model labels them.
    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String] {
        let database = try requireDatabase(for: budgetID)
        let categories = try await database.fetchCategories()
        return Dictionary(uniqueKeysWithValues: categories.compactMap { category in
            category.id.map { ($0, category.name) }
        })
    }

    /// Current → proposed amounts for the undo review, or a typed block reason.
    /// The conflict check also runs inside the commit; this read is display only.
    func budgetActionUndoPreview(actionID: String, budgetID: String) async throws -> BudgetActionUndoPreview {
        let database = try requireDatabase(for: budgetID)
        guard let record = try await database.actionLogRecord(id: actionID) else {
            throw LocalFirstError.invalidLocalWrite("this action is no longer in history")
        }
        return try await database.actionUndoPreview(record: record)
    }

    /// Commits the LIFO undo through the same atomic path as any local write,
    /// then reloads caches and flushes. Undo writes no new history row (Q6).
    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        guard let record = try await database.actionLogRecord(id: actionID) else {
            throw LocalFirstError.invalidLocalWrite("this action is no longer in history")
        }
        _ = try await database.commitActionUndo(record: record)
        try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
    }
}
