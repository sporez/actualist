import Foundation
import GRDB

extension BudgetDatabase {
    /// The shared structural check for an imported budget file (server
    /// download and portable ZIP): `PRAGMA integrity_check` passes, the four
    /// core tables exist, and they carry the columns Actualist reads. Callers
    /// map `false` to their own error type; portable import additionally
    /// rejects unknown migrations, and export is unchecked like upstream.
    static func hasRequiredBudgetSchema(in db: Database) throws -> Bool {
        let integrity = try String.fetchAll(db, sql: "PRAGMA integrity_check")
        guard integrity == ["ok"] else { return false }

        let requiredTables = ["accounts", "transactions", "categories", "category_groups"]
        for table in requiredTables {
            guard try Row.fetchOne(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                arguments: [table]
            ) != nil else {
                return false
            }
        }

        func columns(of table: String) throws -> Set<String> {
            Set(
                try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                    .compactMap { $0["name"] as String? }
            )
        }
        let transactions = try columns(of: "transactions")
        return try columns(of: "accounts").isSuperset(of: ["id", "name"])
            && transactions.isSuperset(of: ["id", "date", "amount"])
            && (transactions.contains("acct") || transactions.contains("account"))
            && columns(of: "categories").isSuperset(of: ["id", "name"])
            && columns(of: "category_groups").isSuperset(of: ["id", "name"])
    }
}
