import Foundation
import GRDB

struct RawReportActivityDay: Sendable {
    let dayID: String
    let categoryID: String?
    let isIncome: Bool
    let isTransfer: Bool
    let isInflow: Bool
    let amount: Int
}

extension BudgetDatabase {
    func reportActivityDays(
        from startDay: String,
        through endDay: String,
        db: Database
    ) throws -> [RawReportActivityDay] {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return []
        }
        let transactionColumns = try columnSet(for: "transactions", db: db)
        let accountColumns = try columnSet(for: "accounts", db: db)
        let split = transactionSplitQueryExpressions(columns: transactionColumns)
        let joins = try transactionReadJoins(
            db: db,
            split: split,
            transactionColumns: transactionColumns,
            includeNames: false
        )
        let normalizedDate = normalizedDateExpression(split.qualifiedDate)
        let offBudget = column("offbudget", fallback: "0", columns: accountColumns)
        let hasCategories = try tableExists("categories", db: db)
        let hasGroups = hasCategories ? try tableExists("category_groups", db: db) : false
        var categoryJoin = ""
        var groupJoin = ""
        var isIncome = "0"
        if hasCategories {
            let columns = try columnSet(for: "categories", db: db)
            let categoryIncome = columns.contains("is_income") ? "c.is_income" : "0"
            let categoryGroup = columns.contains("cat_group")
                ? "c.cat_group"
                : columns.contains("group_id") ? "c.group_id" : "NULL"
            categoryJoin = "LEFT JOIN categories c ON c.id = \(joins.mappedCategory)"
            if hasGroups {
                let groupColumns = try columnSet(for: "category_groups", db: db)
                let groupIncome = groupColumns.contains("is_income") ? "g.is_income" : "0"
                groupJoin = "LEFT JOIN category_groups g ON g.id = \(categoryGroup)"
                isIncome = "CASE WHEN COALESCE(\(categoryIncome), 0) != 0 OR COALESCE(\(groupIncome), 0) != 0 THEN 1 ELSE 0 END"
            } else {
                isIncome = "CASE WHEN COALESCE(\(categoryIncome), 0) != 0 THEN 1 ELSE 0 END"
            }
        }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(normalizedDate) AS day,
                       \(joins.mappedCategory) AS category_id,
                       \(isIncome) AS is_income,
                       \(joins.isTransferExpression) AS is_transfer,
                       CASE WHEN \(split.qualifiedAmount) > 0 THEN 1 ELSE 0 END AS is_inflow,
                       SUM(\(split.qualifiedAmount)) AS amount
                FROM transactions t
                JOIN accounts a ON a.id = \(split.qualifiedAccount)
                \(split.parentJoin())
                \(joins.sql)
                \(categoryJoin)
                \(groupJoin)
                WHERE \(split.liveInlinePredicate())
                  AND \(predicateForLiveRows(columns: accountColumns, tableAlias: "a"))
                  AND COALESCE(a.\(offBudget), 0) = 0
                  AND \(normalizedDate) BETWEEN ? AND ?
                GROUP BY 1, 2, 3, 4, 5
                ORDER BY \(normalizedDate)
                """,
            arguments: [startDay, endDay]
        )
        return rows.compactMap { row in
            guard let dayID = flexibleString(row["day"]) else { return nil }
            return RawReportActivityDay(
                dayID: dayID,
                categoryID: flexibleString(row["category_id"]),
                isIncome: flexibleBool(row["is_income"]),
                isTransfer: flexibleBool(row["is_transfer"]),
                isInflow: flexibleBool(row["is_inflow"]),
                amount: row["amount"] ?? 0
            )
        }
    }

    func reportActivityDays(
        from contributors: [ActualTransaction],
        catalog: ReportExplorerFilterCatalog
    ) -> [RawReportActivityDay] {
        let incomeCategoryIDs = Set(catalog.categories.lazy.filter(\.isIncome).map(\.id))
        return contributors.compactMap { transaction in
            guard let amount = transaction.amount else { return nil }
            return RawReportActivityDay(
                dayID: transaction.date,
                categoryID: transaction.category,
                isIncome: transaction.category.map(incomeCategoryIDs.contains) ?? false,
                isTransfer: false,
                isInflow: amount > 0,
                amount: amount
            )
        }
    }

    /// Budgeted expenses for one month over explicit live expense category ids.
    /// Budget rows of deleted categories are excluded by the id list, and a
    /// delete-with-transfer already moved the amount onto the destination row,
    /// so `category_mapping` is deliberately not joined here.
    func reportBudgetedExpenses(
        month: String,
        categoryIDs: Set<String>,
        db: Database
    ) throws -> Int {
        let table = try budgetTable(db: db)
        guard try tableExists(table.rawValue, db: db), !categoryIDs.isEmpty else { return 0 }

        let budgetColumns = try columnSet(for: table.rawValue, db: db)
        let budgetAmount = column("amount", fallback: "0", columns: budgetColumns)
        let budgetMonth = column("month", fallback: "NULL", columns: budgetColumns)
        let budgetCategory = column("category", fallback: "NULL", columns: budgetColumns)
        let normalizedMonth = normalizedMonthExpression("z.\(budgetMonth)")
        let sortedCategoryIDs = categoryIDs.sorted()
        let placeholders = Array(repeating: "?", count: sortedCategoryIDs.count).joined(separator: ", ")
        var arguments: [DatabaseValueConvertible] = [month]
        arguments.append(contentsOf: sortedCategoryIDs)

        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT SUM(z.\(budgetAmount)) AS amount
                FROM \(quotedIdentifier(table.rawValue)) z
                WHERE \(normalizedMonth) = ?
                  AND z.\(budgetCategory) IN (\(placeholders))
                """,
            arguments: StatementArguments(arguments)
        )
        return row?["amount"] ?? 0
    }

    /// Dashboard variant: live non-income categories. Envelope budgets keep
    /// hidden categories; tracking budgets exclude them (upstream
    /// budget-analysis-spreadsheet `showHiddenCategories || !cat.hidden`).
    func reportBudgetedExpenses(month: String, db: Database) throws -> Int {
        let includesHidden = try !isTrackingBudget(db: db)
        let catalog = try reportExplorerFilterCatalog(db: db)
        let categoryIDs = Set(catalog.categories.lazy.filter {
            !$0.isIncome && (includesHidden || !$0.isHidden)
        }.map(\.id))
        return try reportBudgetedExpenses(month: month, categoryIDs: categoryIDs, db: db)
    }
}
