import Foundation
import GRDB

extension BudgetDatabase {

    func fetchAvailableMonths() throws -> [String] {
        try queue.read { db in try fetchAvailableMonths(db: db) }
    }

    func fetchAvailableMonths(db: Database) throws -> [String] {
        var months = Set<String>()
        let table = try budgetTable(db: db).rawValue
        if try tableExists(table, db: db), try columnSet(for: table, db: db).contains("month") {
            let normalizedMonth = normalizedMonthExpression("month")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT \(normalizedMonth) AS month
                    FROM \(quotedIdentifier(table))
                    WHERE month IS NOT NULL
                    """
            )
            months.formUnion(rows.compactMap { YearMonth.canonicalID(SQLiteValueCoercion.lenientString($0["month"])) })
        }
        if try tableExists("transactions", db: db), try columnSet(for: "transactions", db: db).contains("date") {
            let columns = try columnSet(for: "transactions", db: db)
            // Envelope keeps deleted rows' months: upstream sizes the month range from the
            // earliest row of the raw `transactions` table (`createAllBudgets`, budget/base.ts),
            // tombstones included. Tracking filters them here, which upstream does not do.
            let live = table == BudgetTable.tracking.rawValue ? predicateForLiveRows(columns: columns) : "1 = 1"
            let normalizedMonth = normalizedMonthExpression("date")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT \(normalizedMonth) AS month
                    FROM transactions
                    WHERE date IS NOT NULL AND \(live)
                    """
            )
            months.formUnion(rows.compactMap { YearMonth.canonicalID(SQLiteValueCoercion.lenientString($0["month"])) })
        }
        return months.sorted()
    }
}
