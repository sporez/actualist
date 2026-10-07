import Foundation
import GRDB

/// The one definition of which History rows take part in the strict-LIFO undo
/// order. `HistoryViewModel` picks the undoable row with `participates(_:)`; the
/// commit-time check counts newer rows with `participatingRowsFilter`. Both derive
/// from the same two facts: money-flow kinds, and sources that are user gestures.
enum BudgetActionUndoOrder {
    static func participates(kind: BudgetActionKind, source: BudgetActionSource) -> Bool {
        kind.isMoneyFlow && source != .automatic
    }

    static func participates(_ record: BudgetActionRecord) -> Bool {
        participates(kind: record.kind, source: record.source)
    }

    /// SQL for the same predicate over `actualist_action_log` rows.
    static var participatingRowsFilter: (sql: String, arguments: [String]) {
        let kinds = BudgetActionKind.moneyFlowRawValues
        let placeholders = kinds.map { _ in "?" }.joined(separator: ", ")
        return ("kind IN (\(placeholders)) AND source <> ?", kinds + [BudgetActionSource.automatic.rawValue])
    }
}

extension BudgetDatabase {
    /// Storage-level LIFO: undo is only offered for the newest applied row, and the
    /// commit re-checks it so a Shortcuts write that landed after the review sheet
    /// opened cannot be silently skipped. Automatic posts are not undoable and never
    /// block another row.
    func requireNewestAppliedUndo(record: BudgetActionRecord, db: Database) throws {
        guard record.source != .automatic else {
            throw LocalFirstError.actionUndoBlocked("This was posted automatically and can't be undone.")
        }
        let createdAt = SyncTimestamp.wallTimeString(for: record.createdAt)
        let filter = BudgetActionUndoOrder.participatingRowsFilter
        let newerApplied = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM actualist_action_log
                WHERE status = ?
                  AND \(filter.sql)
                  AND (created_at > ? OR (created_at = ? AND id > ?))
                """,
            arguments: StatementArguments(
                [BudgetActionStatus.applied.rawValue] + filter.arguments + [createdAt, createdAt, record.id]
            )
        ) ?? 0
        guard newerApplied == 0 else {
            throw LocalFirstError.actionUndoBlocked("Undo the newest action before this one.")
        }
    }
}
