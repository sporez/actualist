import Foundation

/// The local money-flow gesture log on the store: History reads, the LIFO
/// undo with the reload that follows, and the diagnostics snapshot. The store
/// owns it and keeps the observed `actionLogDiagnosticSnapshot`.
@MainActor
final class HistoryWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    /// Count and newest-row age for diagnostics. Uses the snapshot refreshed
    /// after open and local writes so Settings can stay synchronous.
    func actionLogDiagnosticStats(now: Date = Date()) -> (count: Int, newestAgeSeconds: Int?) {
        let age = store.actionLogDiagnosticSnapshot.newestCreatedAt.map {
            max(0, Int(now.timeIntervalSince($0)))
        }
        return (store.actionLogDiagnosticSnapshot.count, age)
    }

    func refreshActionLogDiagnosticSnapshot(database: BudgetDatabase? = nil) async {
        guard let database = database ?? store.database else {
            store.actionLogDiagnosticSnapshot = .empty
            return
        }
        let generation = store.budgetSessionGeneration
        let snapshot = (try? await ActionLogStorageSQL.actionLogDiagnosticSnapshot(in: database)) ?? .empty
        // A budget switch or teardown during the read must not publish the old
        // budget's counts over the new session's snapshot.
        guard generation == store.budgetSessionGeneration, store.database === database else { return }
        store.actionLogDiagnosticSnapshot = snapshot
    }

    /// Newest-first local money-flow gestures for the open budget. The rows
    /// live inside that budget's SQLite, so a budget switch or reimport never
    /// leaks another budget's history.
    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord] {
        let database = try store.requireDatabase(for: budgetID)
        return try await ActionLogStorageSQL.recentBudgetActions(in: database)
    }

    /// Live and historical category names for History rows. Deleted categories
    /// simply have no entry; the view model labels them.
    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String] {
        let database = try store.requireDatabase(for: budgetID)
        let categories = try await CategorySQL.fetchCategories(in: database)
        return categories.namesByID
    }

    /// Current → proposed amounts for the undo review, or a typed block reason.
    /// The conflict check also runs inside the commit; this read is display only.
    func budgetActionUndoPreview(actionID: String, budgetID: String) async throws -> BudgetActionUndoPreview {
        let database = try store.requireDatabase(for: budgetID)
        guard let record = try await ActionLogStorageSQL.actionLogRecord(id: actionID, in: database) else {
            throw LocalFirstError.refusedChange("This action is no longer in History.")
        }
        return try await ActionLogSQL.actionUndoPreview(record: record, in: database)
    }

    /// Commits the LIFO undo through the same atomic path as any local write,
    /// then reloads caches and flushes. Undo writes no new history row (Q6).
    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws {
        let database = try store.requireDatabase(for: budgetID)
        guard let record = try await ActionLogStorageSQL.actionLogRecord(id: actionID, in: database) else {
            throw LocalFirstError.refusedChange("This action is no longer in History.")
        }
        _ = try await database.commitActionUndo(record: record)
        // One reload covers budget, account and every loaded transaction feed.
        try await store.finishCommittedBudgetWrite(database: database, budgetID: budgetID)
    }
}

extension HistoryWorkflows: BudgetHistoryRepositoryProtocol { }
