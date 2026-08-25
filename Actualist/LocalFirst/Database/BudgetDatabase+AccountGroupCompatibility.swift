import Foundation
import GRDB

extension BudgetDatabase {
    // Old imports may have retained account group CRDT without the physical table/column.
    static func prepareAccountGroupCompatibility(in queue: DatabaseQueue) throws {
        try queue.write { db in
            let accountTableExists = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM sqlite_master
                        WHERE type = 'table' AND name = 'accounts'
                    )
                    """
            ) ?? false
            guard accountTableExists else {
                return
            }

            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS account_groups (
                        id TEXT PRIMARY KEY,
                        name TEXT,
                        sort_order REAL,
                        tombstone INTEGER DEFAULT 0
                    )
                    """
            )

            let accountColumns = try Set(
                Row.fetchAll(db, sql: "PRAGMA table_info(accounts)")
                    .compactMap { $0["name"] as String? }
            )
            if !accountColumns.contains("account_group_id") {
                try db.execute(
                    sql: "ALTER TABLE accounts ADD COLUMN account_group_id TEXT DEFAULT NULL"
                )
            }

            let messagesTableExists = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM sqlite_master
                        WHERE type = 'table' AND name = 'messages_crdt'
                    )
                    """
            ) ?? false
            guard messagesTableExists else {
                return
            }

            let groupColumns = try Set(
                Row.fetchAll(db, sql: "PRAGMA table_info(account_groups)")
                    .compactMap { $0["name"] as String? }
            )
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT dataset, row, column, value
                    FROM messages_crdt
                    WHERE dataset = 'account_groups'
                       OR (dataset = 'accounts' AND column = 'account_group_id')
                    ORDER BY timestamp
                    """
            )

            for row in rows {
                guard let dataset = row["dataset"] as String?,
                      let rowID = row["row"] as String?,
                      let column = row["column"] as String?,
                      let serializedValue = row["value"] as String?,
                      !rowID.isEmpty,
                      !column.isEmpty,
                      let value = decodeCompatibilitySyncValue(serializedValue) else {
                    continue
                }

                if dataset == "account_groups" {
                    guard groupColumns.contains(column) else {
                        continue
                    }
                    let exists = try Row.fetchOne(
                        db,
                        sql: "SELECT id FROM account_groups WHERE id = ? LIMIT 1",
                        arguments: [rowID]
                    ) != nil
                    try applyCompatibilityValue(
                        value,
                        table: "account_groups",
                        column: column,
                        rowID: rowID,
                        rowExists: exists,
                        db: db
                    )
                    continue
                }

                guard dataset == "accounts", column == "account_group_id" else {
                    continue
                }
                let exists = try Row.fetchOne(
                    db,
                    sql: "SELECT id FROM accounts WHERE id = ? LIMIT 1",
                    arguments: [rowID]
                ) != nil
                guard exists else {
                    continue
                }
                try applyCompatibilityValue(
                    value,
                    table: "accounts",
                    column: column,
                    rowID: rowID,
                    rowExists: true,
                    db: db
                )
            }
        }
    }

    // Matches `deserializeSyncValue` so replay uses the same 0: / N: / S: rules as sync.
    private static func decodeCompatibilitySyncValue(_ value: String) -> ActualSyncSQLiteValue? {
        guard let type = value.first else {
            return nil
        }
        let payload = String(value.dropFirst(2))
        switch type {
        case "0":
            return .null
        case "N":
            guard let number = Double(payload), number.isFinite else {
                return nil
            }
            if number.rounded() == number, let int = Int64(exactly: number) {
                return .int(int)
            }
            return .double(number)
        case "S":
            return .string(payload)
        default:
            return nil
        }
    }

    private static func applyCompatibilityValue(
        _ value: ActualSyncSQLiteValue,
        table: String,
        column: String,
        rowID: String,
        rowExists: Bool,
        db: Database
    ) throws {
        let tableSQL = quotedCompatibilityIdentifier(table)
        let columnSQL = quotedCompatibilityIdentifier(column)
        if rowExists {
            switch value {
            case .null:
                try db.execute(
                    sql: "UPDATE \(tableSQL) SET \(columnSQL) = NULL WHERE id = ?",
                    arguments: [rowID]
                )
            case .int(let value):
                try db.execute(
                    sql: "UPDATE \(tableSQL) SET \(columnSQL) = ? WHERE id = ?",
                    arguments: [value, rowID]
                )
            case .double(let value):
                try db.execute(
                    sql: "UPDATE \(tableSQL) SET \(columnSQL) = ? WHERE id = ?",
                    arguments: [value, rowID]
                )
            case .string(let value):
                try db.execute(
                    sql: "UPDATE \(tableSQL) SET \(columnSQL) = ? WHERE id = ?",
                    arguments: [value, rowID]
                )
            }
            return
        }

        switch value {
        case .null:
            try db.execute(
                sql: "INSERT INTO \(tableSQL) (id, \(columnSQL)) VALUES (?, NULL)",
                arguments: [rowID]
            )
        case .int(let value):
            try db.execute(
                sql: "INSERT INTO \(tableSQL) (id, \(columnSQL)) VALUES (?, ?)",
                arguments: [rowID, value]
            )
        case .double(let value):
            try db.execute(
                sql: "INSERT INTO \(tableSQL) (id, \(columnSQL)) VALUES (?, ?)",
                arguments: [rowID, value]
            )
        case .string(let value):
            try db.execute(
                sql: "INSERT INTO \(tableSQL) (id, \(columnSQL)) VALUES (?, ?)",
                arguments: [rowID, value]
            )
        }
    }

    private static func quotedCompatibilityIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
