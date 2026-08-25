import Foundation
import GRDB

extension BudgetDatabase {
    func fetchBudgetCurrency() throws -> BudgetCurrency {
        try queue.read { db in
            BudgetCurrency.catalog(
                code: try preferenceValue("defaultCurrencyCode", db: db) ?? "",
                hideFraction: try preferenceValue("hideFraction", db: db) == "true"
            )
        }
    }

    private func preferenceValue(_ id: String, db: Database) throws -> String? {
        guard try tableExists("preferences", db: db) else {
            return nil
        }
        let columns = try columnSet(for: "preferences", db: db)
        guard columns.contains("id"), columns.contains("value") else {
            return nil
        }
        let tombstone = columns.contains("tombstone")
            ? "AND (tombstone = 0 OR tombstone IS NULL)"
            : ""
        return try String.fetchOne(
            db,
            sql: "SELECT value FROM preferences WHERE id = ? \(tombstone) LIMIT 1",
            arguments: [id]
        )
    }
}
