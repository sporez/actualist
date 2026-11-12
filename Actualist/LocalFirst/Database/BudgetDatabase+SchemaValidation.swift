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
            guard try SQLiteSchema.tableExists(table, in: db) else {
                return false
            }
        }

        func columns(of table: String) throws -> Set<String> {
            try SQLiteSchema.columns(of: table, in: db)
        }
        let transactions = try columns(of: "transactions")
        return try columns(of: "accounts").isSuperset(of: ["id", "name"])
            && transactions.isSuperset(of: ["id", "date", "amount"])
            && TransactionRowColumns.account(in: transactions) != nil
            && columns(of: "categories").isSuperset(of: ["id", "name"])
            && columns(of: "category_groups").isSuperset(of: ["id", "name"])
    }
}
