import Foundation
import GRDB

/// Reads one raw `transactions` row. The split record, batch snapshot and undo
/// snapshot loaders each project the row into their own record, on purpose:
/// they differ in what an empty string means, in which numeric reads they
/// accept and in how `isChild` is derived. Only the fetch and the pieces all
/// of them read the same way live here. Stateless.
enum TransactionRowReader {
    /// The stored row, or nil when there is none. All columns come back; each
    /// loader reads the ones it needs through `TransactionRowColumns`.
    static func row(id: String, db: Database) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: "SELECT * FROM transactions WHERE id = ?",
            arguments: [id]
        )
    }

    /// `parent_id` with the empty string as nil; nil when there is no such column.
    static func parentID(in row: Row, columns: BudgetDatabase.TransactionRowColumns) -> String? {
        columns.hasParentID ? SQLiteValueCoercion.nonEmptyString(row, "parent_id") : nil
    }

    /// The child flag, or whether `parentID` is set when the flag is missing or
    /// NULL. An explicit zero wins over a `parentID`.
    static func effectiveIsChild(
        row: Row,
        columns: BudgetDatabase.TransactionRowColumns,
        parentID: String?
    ) -> Bool {
        guard let isChildColumn = columns.isChild else {
            return parentID != nil
        }
        let value = SQLiteValueCoercion.int(row, isChildColumn)
        if value == nil {
            return parentID != nil
        }
        return value != 0
    }
}
