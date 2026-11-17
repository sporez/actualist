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
