import Foundation
import GRDB

extension BudgetDatabase {
    /// One-time migration name for the account-group compatibility replay below.
    static let accountGroupCompatibilityMigration = "account-group-compatibility-v1"

    // Old imports may have retained account group CRDT without the physical table/column.
    //
    // The physical schema is ensured on every open (cheap, and required before any
    // read of `accounts`/`account_groups`). The historical `messages_crdt` replay
    // runs once per file: it exists to materialize CRDT that predates the physical
    // columns, and later sync writes those columns directly.
    //
    // Audit of the sibling preparations, which need no watermark:
    // `prepareBankSyncStatusCompatibility` already returns early once
    // `accounts.bank_sync_status` exists; `prepareBankSyncSchemaCompatibility`
    // and `prepareBudgetIdentity` are DDL-only and must stay unconditional so
    // local writes keep validating on older imports.
    static func prepareAccountGroupCompatibility(in queue: DatabaseQueue) throws {
        try queue.write { db in
            let accountTableExists = try SQLiteSchema.tableExists("accounts", in: db)
            guard accountTableExists else {
                return
            }

            let groupsTableExisted = try SQLiteSchema.tableExists("account_groups", in: db)
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

            let accountColumns = try SQLiteSchema.columns(of: "accounts", in: db)
            let addedGroupColumn = !accountColumns.contains("account_group_id")
            if addedGroupColumn {
                try db.execute(
                    sql: "ALTER TABLE accounts ADD COLUMN account_group_id TEXT DEFAULT NULL"
                )
            }
            if addedGroupColumn || !groupsTableExisted {
                try recordAccountGroupsMigrationID(in: db)
            }

            guard !(try localMigrationApplied(accountGroupCompatibilityMigration, in: db)) else {
                return
            }

            let messagesTableExists = try SQLiteSchema.tableExists("messages_crdt", in: db)
            guard messagesTableExists else {
                try recordLocalMigration(accountGroupCompatibilityMigration, in: db)
                return
            }

            let groupColumns = try SQLiteSchema.columns(of: "account_groups", in: db)
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
                      let value = try? ActualSyncSQLiteValue(serialized: serializedValue) else {
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

            try recordLocalMigration(accountGroupCompatibilityMigration, in: db)
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
