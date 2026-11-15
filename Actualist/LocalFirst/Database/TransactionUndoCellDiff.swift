import Foundation
import GRDB

/// Keeps only the cells of a History undo that change the stored row. Actual's
/// undo writes back just the cells its action changed (`undoWrites`), so a cell
/// another device may have edited since is never overwritten with its old
/// value. The undo gate already refuses when the rows changed after the
/// action, so the cells that differ are exactly the ones the action changed.
/// Stateless.
enum TransactionUndoCellDiff {
    /// The 0/1 columns an undo snapshot reads with NULL as false (the undo snapshot loaders
    /// read them through `SQLiteValueCoercion.int ?? 0`), so a stored NULL is not a change.
    static func flagColumns(_ columns: TransactionRowColumns) -> Set<String> {
        Set(["cleared", "reconciled", "tombstone", "starting_balance_flag"] + [columns.isParent, columns.isChild].compactMap { $0 })
    }

    /// `messages` for one row, minus every message whose value already equals
    /// the stored cell. A missing column reads as NULL; a missing row keeps all
    /// messages. Numbers compare by value, so `100` equals `100.0`; text and
    /// numbers never equal each other. A stored NULL in a `flagColumns` column
    /// equals 0.
    static func changedCells(
        _ messages: [ActualSyncDecodedMessage],
        currentRow row: Row?,
        flagColumns: Set<String>
    ) throws -> [ActualSyncDecodedMessage] {
        guard let row else { return messages }
        return try messages.filter { message in
            let cell: DatabaseValue? = row.hasColumn(message.column) ? row[message.column] : nil
            let new = try ActualSyncSQLiteValue(serialized: message.serializedValue)
            if flagColumns.contains(message.column), cell?.isNull ?? true, case .int(0) = new {
                return false
            }
            return !stored(cell, equals: new)
        }
    }

    static func stored(_ value: DatabaseValue?, equals sync: ActualSyncSQLiteValue) -> Bool {
        guard let value else {
            if case .null = sync { return true }
            return false
        }
        switch (value.storage, sync) {
        case (.null, .null):
            return true
        case (.int64(let stored), .int(let new)):
            return stored == new
        case (.int64(let stored), .double(let new)):
            return Double(stored) == new
        case (.double(let stored), .int(let new)):
            return stored == Double(new)
        case (.double(let stored), .double(let new)):
            return stored == new
        case (.string(let stored), .string(let new)):
            return stored == new
        default:
            return false
        }
    }
}
