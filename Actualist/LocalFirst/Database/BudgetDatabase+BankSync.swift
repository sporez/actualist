import Foundation
import GRDB

extension BudgetDatabase {
    /// Open-time backfill for SimpleFIN bank sync. Imported budgets may lack
    /// the `banks` table and the account link columns that Actual's
    /// `linkSimpleFinAccount` writes. Creating them here keeps local CRDT
    /// writes (`validateLocalMessage`) from rejecting link/unlink messages on
    /// older imports. Mirrors the existing `bank_sync_status` backfill.
    static func prepareBankSyncSchemaCompatibility(in queue: DatabaseQueue) throws {
        try queue.write { db in
            let accountsTableExists = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM sqlite_master
                        WHERE type = 'table' AND name = 'accounts'
                    )
                    """
            ) ?? false

            if accountsTableExists {
                let accountColumns = try Set(
                    Row.fetchAll(db, sql: "PRAGMA table_info(accounts)")
                        .compactMap { $0["name"] as String? }
                )
                let linkColumns: [(column: String, ddl: String)] = [
                    ("account_id", "TEXT"),
                    ("account_sync_source", "TEXT"),
                    ("bank", "TEXT"),
                    ("balance_current", "INTEGER"),
                    ("balance_available", "INTEGER"),
                    ("balance_limit", "INTEGER"),
                    ("last_sync", "TEXT"),
                ]
                for linkColumn in linkColumns
                where !accountColumns.contains(linkColumn.column) {
                    try db.execute(
                        sql: "ALTER TABLE accounts ADD COLUMN \(linkColumn.column) \(linkColumn.ddl)"
                    )
                }
            }

            let banksTableExists = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM sqlite_master
                        WHERE type = 'table' AND name = 'banks'
                    )
                    """
            ) ?? false
            if !banksTableExists {
                // loot-core parity: banks (id, bank_id, name).
                try db.execute(
                    sql: "CREATE TABLE banks (id TEXT PRIMARY KEY, bank_id TEXT, name TEXT)"
                )
            }
        }
    }

    struct BankSyncBankRow: Equatable, Sendable {
        let id: String
        let bankID: String
        let name: String?
    }

    /// loot-core `findOrCreateBank`: match on **both** `bank_id` and `name`.
    /// The same `(bank_id, name)` pair reuses the row; the same `bank_id` with
    /// a different name creates a distinct bank row.
    func findOrCreateBank(
        bankID: String,
        name: String?,
        makeID: @Sendable () -> String
    ) throws -> BankSyncBankRow {
        try queue.write { db in
            let columns = try columnSet(for: "banks", db: db)
            guard columns.contains("bank_id") else {
                throw LocalFirstError.invalidLocalWrite("missing column banks.bank_id")
            }

            let existingRow: Row?
            if let name {
                existingRow = try Row.fetchOne(
                    db,
                    sql: "SELECT id, bank_id, name FROM banks WHERE bank_id = ? AND name IS ? LIMIT 1",
                    arguments: [bankID, name]
                )
            } else {
                existingRow = try Row.fetchOne(
                    db,
                    sql: "SELECT id, bank_id, name FROM banks WHERE bank_id = ? AND name IS NULL LIMIT 1",
                    arguments: [bankID]
                )
            }

            if let existingRow,
               let id: String = existingRow["id"],
               let existingBankID: String = existingRow["bank_id"] {
                return BankSyncBankRow(
                    id: id,
                    bankID: existingBankID,
                    name: existingRow["name"]
                )
            }

            let id = makeID()
            try db.execute(
                sql: "INSERT INTO banks (id, bank_id, name) VALUES (?, ?, ?)",
                arguments: [id, bankID, name]
            )
            return BankSyncBankRow(id: id, bankID: bankID, name: name)
        }
    }
}
