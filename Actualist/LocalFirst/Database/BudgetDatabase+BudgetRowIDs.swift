import Foundation
import GRDB

extension BudgetDatabase {
    /// Existing budget row ids by normalized month, then category, from one
    /// read. The first row for a month and category decides, as `budgetRowID`'s
    /// `LIMIT 1` does; categories with no stored row are absent.
    func budgetRowIDs(
        table: BudgetTable,
        columns: Set<String>,
        db: Database
    ) throws -> [String: [String: String]] {
        let monthColumn = column("month", fallback: "NULL", columns: columns)
        let categoryColumn = column("category", fallback: "NULL", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(normalizedMonthExpression(monthColumn)) AS month,
                       \(categoryColumn) AS category,
                       \(columns.contains("id") ? "id" : "NULL") AS id
                FROM \(quotedIdentifier(table.rawValue))
                """
        )
        var result: [String: [String: String]] = [:]
        var seen: Set<String> = []
        for row in rows {
            guard let month = row["month"] as String?, let categoryID = row["category"] as String?,
                  seen.insert("\(month)\u{0}\(categoryID)").inserted else {
                continue
            }
            // Without an id column the row id is the derived one, as in `budgetRowID`.
            let id = columns.contains("id")
                ? row["id"] as String?
                : Self.budgetRowID(monthValue: monthInt(month), categoryID: categoryID)
            if let id {
                result[month, default: [:]][categoryID] = id
            }
        }
        return result
    }
}
