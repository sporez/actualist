import Foundation
import GRDB

enum BudgetRowSQL {
    /// Existing budget row ids by normalized month, then category, from one
    /// read. The first row for a month and category decides, as `budgetRowID`'s
    /// `LIMIT 1` does; categories with no stored row are absent.
    static func budgetRowIDs(
        table: BudgetTable,
        columns: Set<String>,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [String: [String: String]] {
        let monthColumn = database.column("month", fallback: "NULL", columns: columns)
        let categoryColumn = database.column("category", fallback: "NULL", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(database.normalizedMonthExpression(monthColumn)) AS month,
                       \(categoryColumn) AS category,
                       \(columns.contains("id") ? "id" : "NULL") AS id
                FROM \(database.quotedIdentifier(table.rawValue))
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
                : Self.budgetRowID(monthValue: YearMonth.packedUnchecked(month), categoryID: categoryID)
            if let id {
                result[month, default: [:]][categoryID] = id
            }
        }
        return result
    }

    static func assignCategoryBudgetMessages(
        categoryID: String,
        budgeted: Int,
        monthValue: Int,
        table: BudgetTable,
        columns: Set<String>,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        let existingRowID = try budgetRowID(
            table: table,
            monthValue: monthValue,
            categoryID: categoryID,
            columns: columns,
            in: database,
            db: db
        )
        let rowID = existingRowID ?? Self.budgetRowID(monthValue: monthValue, categoryID: categoryID)
        let dataset = table.rawValue
        // Actual's setBudget updates an existing row's amount and inserts a new
        // row with only its identity cells and amount.
        var messages: [ActualSyncDecodedMessage] = []
        if existingRowID == nil {
            messages += try budgetRowIdentityMessages(
                table: table, rowID: rowID, monthValue: monthValue,
                categoryID: categoryID, builder: &builder
            )
        }
        messages.append(
            try builder.makeMessage(
                dataset: dataset,
                row: rowID,
                column: "amount",
                value: .int(Int64(budgeted))
            )
        )
        return messages
    }

    static func budgetRowID(
        table: BudgetTable,
        monthValue: Int,
        categoryID: String,
        columns: Set<String>,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> String? {
        let monthColumn = database.column("month", fallback: "NULL", columns: columns)
        let categoryColumn = database.column("category", fallback: "NULL", columns: columns)
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT \(columns.contains("id") ? "id" : "NULL") AS id
                FROM \(database.quotedIdentifier(table.rawValue))
                WHERE \(database.normalizedMonthExpression(monthColumn)) = ? AND \(categoryColumn) = ?
                LIMIT 1
                """,
            arguments: [YearMonth.id(packed: monthValue), categoryID]
        )
        if columns.contains("id") {
            return row?["id"] as String?
        }
        return row == nil ? nil : Self.budgetRowID(monthValue: monthValue, categoryID: categoryID)
    }

    /// The `month` and `category` cells that identify a new budget row to a peer, in
    /// that order. The caller appends its own cells after them. Actual's carryover
    /// writers store the month as text; its amount writers store a number.
    static func budgetRowIdentityMessages(
        table: BudgetTable,
        rowID: String,
        monthValue: Int,
        categoryID: String,
        monthAsText: Bool = false,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        [
            try builder.makeMessage(
                dataset: table.rawValue,
                row: rowID,
                column: "month",
                value: monthAsText ? .string(String(monthValue)) : .int(Int64(monthValue))
            ),
            try builder.makeMessage(
                dataset: table.rawValue,
                row: rowID,
                column: "category",
                value: .string(categoryID)
            )
        ]
    }

    static func budgetRowID(monthValue: Int, categoryID: String) -> String {
        "\(monthValue)-\(categoryID)"
    }

    static func zeroBudgetKey(from rowID: String) throws -> (monthValue: Int, monthID: String, categoryID: String) {
        guard rowID.count > 7 else {
            throw LocalFirstError.invalidLocalWrite("invalid zero_budgets row")
        }
        let monthEnd = rowID.index(rowID.startIndex, offsetBy: 6)
        guard let monthValue = Int(rowID[..<monthEnd]) else {
            throw LocalFirstError.invalidLocalWrite("invalid zero_budgets month")
        }
        let separator = rowID[monthEnd]
        guard separator == "-" else {
            throw LocalFirstError.invalidLocalWrite("invalid zero_budgets row")
        }
        let categoryStart = rowID.index(after: monthEnd)
        let categoryID = String(rowID[categoryStart...])
        guard !categoryID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
        return (monthValue, YearMonth.id(packed: monthValue), categoryID)
    }
}
