import Foundation
import GRDB

struct RawReportActivityDay: Sendable {
    let dayID: String
    let categoryID: String?
    let isIncome: Bool
    let isTransfer: Bool
    let isInflow: Bool
    let amount: Int

    /// Actual's spending rule, shared by the dashboard and the explorer: every
    /// non-income row counts, including uncategorized rows and both sides of
    /// on-budget transfers.
    var isSpending: Bool { !isIncome }

    static func spendingByDay(_ rows: [RawReportActivityDay]) throws -> [String: Int] {
        var spendingByDay: [String: Int] = [:]
        for row in rows where row.isSpending {
            spendingByDay[row.dayID] = try ReportArithmetic.subtract(spendingByDay[row.dayID] ?? 0, row.amount)
        }
        return spendingByDay
    }
}

enum ReportInputSQL {
    static func reportActivityDays(
        from startDay: String,
        through endDay: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [RawReportActivityDay] {
        guard try database.tableExists("transactions", db: db), try database.tableExists("accounts", db: db) else {
            return []
        }
        let transactionColumns = try database.columnSet(for: "transactions", db: db)
        let accountColumns = try database.columnSet(for: "accounts", db: db)
        let split = TransactionSplitQueryExpressions(columns: transactionColumns)
        let joins = try TransactionReadJoins.resolve(
            split: split,
            transactionColumns: transactionColumns,
            includeNames: false,
            in: database,
            db: db
        )
        let normalizedDate = database.normalizedDateExpression(split.qualifiedDate)
        let offBudget = database.column("offbudget", fallback: "0", columns: accountColumns)
        // Actual's spending report decides income by the category's own is_income
        // (spending-spreadsheet.ts filters !categoryIncome); the group's flag is not read.
        var isIncome = "0"
        if try database.tableExists("categories", db: db) {
            let columns = try database.columnSet(for: "categories", db: db)
            let categoryIncome = columns.contains("is_income") ? "cat.is_income" : "0"
            isIncome = "CASE WHEN COALESCE(\(categoryIncome), 0) != 0 THEN 1 ELSE 0 END"
        }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(normalizedDate) AS day,
                       \(joins.liveCategory) AS category_id,
                       \(isIncome) AS is_income,
                       \(joins.isTransferExpression) AS is_transfer,
                       CASE WHEN \(split.qualifiedAmount) > 0 THEN 1 ELSE 0 END AS is_inflow,
                       SUM(\(split.qualifiedAmount)) AS amount
                FROM transactions t
                JOIN accounts a ON a.id = \(split.qualifiedAccount)
                \(split.parentJoin())
                \(joins.sql)
                WHERE \(split.liveInlinePredicate())
                  AND \(database.predicateForLiveRows(columns: accountColumns, tableAlias: "a"))
                  AND COALESCE(a.\(offBudget), 0) = 0
                  AND \(normalizedDate) BETWEEN ? AND ?
                GROUP BY 1, 2, 3, 4, 5
                ORDER BY \(normalizedDate)
                """,
            arguments: [startDay, endDay]
        )
        return rows.compactMap { row in
            guard let dayID = SQLiteValueCoercion.lenientString(row["day"]) else { return nil }
            return RawReportActivityDay(
                dayID: dayID,
                categoryID: SQLiteValueCoercion.lenientString(row["category_id"]),
                isIncome: SQLiteValueCoercion.lenientBool(row["is_income"]),
                isTransfer: SQLiteValueCoercion.lenientBool(row["is_transfer"]),
                isInflow: SQLiteValueCoercion.lenientBool(row["is_inflow"]),
                amount: row["amount"] ?? 0
            )
        }
    }

    static func reportActivityDays(
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
    static func reportBudgetedExpenses(
        month: String,
        categoryIDs: Set<String>,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> Int {
        let table = try database.budgetTable(db: db)
        guard try database.tableExists(table.rawValue, db: db), !categoryIDs.isEmpty else { return 0 }

        let budgetColumns = try database.columnSet(for: table.rawValue, db: db)
        let budgetAmount = database.column("amount", fallback: "0", columns: budgetColumns)
        let budgetMonth = database.column("month", fallback: "NULL", columns: budgetColumns)
        let budgetCategory = database.column("category", fallback: "NULL", columns: budgetColumns)
        let normalizedMonth = database.normalizedMonthExpression("z.\(budgetMonth)")
        let sortedCategoryIDs = categoryIDs.sorted()
        let placeholders = Array(repeating: "?", count: sortedCategoryIDs.count).joined(separator: ", ")
        var arguments: [DatabaseValueConvertible] = [month]
        arguments.append(contentsOf: sortedCategoryIDs)

        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT SUM(z.\(budgetAmount)) AS amount
                FROM \(database.quotedIdentifier(table.rawValue)) z
                WHERE \(normalizedMonth) = ?
                  AND z.\(budgetCategory) IN (\(placeholders))
                """,
            arguments: StatementArguments(arguments)
        )
        return row?["amount"] ?? 0
    }

    /// Dashboard variant: every live non-income category, hidden or not, for
    /// envelope and tracking budgets alike (Actual's `getSpendingBudgetFilters`
    /// in spending-spreadsheet.ts).
    static func reportBudgetedExpenses(month: String, in database: isolated BudgetDatabase, db: Database) throws -> Int {
        let catalog = try reportExplorerFilterCatalog(in: database, db: db)
        let categoryIDs = Set(catalog.categories.lazy.filter { !$0.isIncome }.map(\.id))
        return try reportBudgetedExpenses(month: month, categoryIDs: categoryIDs, in: database, db: db)
    }

    /// Every live transfer-linked row in a live account, optionally limited to
    /// `accountIDs`, in one read. No date bound: a leg after the report's end still
    /// tells the alignment to drop its mate's amount.
    static func reportTransferLegs(accountIDs: Set<String>?, in database: isolated BudgetDatabase, db: Database) throws -> [ReportTransferLeg] {
        guard try database.tableExists("transactions", db: db), try database.tableExists("accounts", db: db) else {
            return []
        }
        let transactionColumns = try database.columnSet(for: "transactions", db: db)
        guard let transferColumn = TransactionRowColumns.transferID(in: transactionColumns) else {
            return []
        }
        let accountColumns = try database.columnSet(for: "accounts", db: db)
        let split = TransactionSplitQueryExpressions(columns: transactionColumns)
        let sortedAccountIDs = accountIDs?.sorted() ?? []
        let accountFilter = accountIDs == nil
            ? ""
            : "AND \(split.qualifiedAccount) IN (\(Array(repeating: "?", count: sortedAccountIDs.count).joined(separator: ", ")))"
        if accountIDs != nil, sortedAccountIDs.isEmpty { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT t.id AS id,
                       t.\(transferColumn) AS transfer_id,
                       \(split.qualifiedAccount) AS account,
                       \(split.qualifiedAmount) AS amount,
                       \(database.normalizedDateExpression(split.qualifiedDate)) AS day
                FROM transactions t
                JOIN accounts a ON a.id = \(split.qualifiedAccount)
                \(split.parentJoin())
                WHERE \(split.liveInlinePredicate())
                  AND \(database.predicateForLiveRows(columns: accountColumns, tableAlias: "a"))
                  AND t.\(transferColumn) IS NOT NULL
                  \(accountFilter)
                """,
            arguments: StatementArguments(sortedAccountIDs)
        )
        return rows.compactMap { row in
            guard let id = SQLiteValueCoercion.lenientString(row["id"]),
                  let transferID = SQLiteValueCoercion.lenientString(row["transfer_id"]),
                  let account = SQLiteValueCoercion.lenientString(row["account"]),
                  let day = SQLiteValueCoercion.lenientString(row["day"]) else { return nil }
            return ReportTransferLeg(
                id: id,
                transferID: transferID,
                accountID: account,
                amount: row["amount"] ?? 0,
                dayID: day
            )
        }
    }

    static func reportExplorerFilterCatalog(in database: isolated BudgetDatabase, db: Database) throws -> ReportExplorerFilterCatalog {
        let accounts: [ReportExplorerAccountFilterOption]
        if try database.tableExists("accounts", db: db) {
            let columns = try database.columnSet(for: "accounts", db: db)
            let name = database.column("name", fallback: "id", columns: columns)
            let offBudget = database.column("offbudget", fallback: "0", columns: columns)
            let closed = database.column("closed", fallback: "0", columns: columns)
            accounts = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, \(name) AS name, \(offBudget) AS offbudget, \(closed) AS closed
                    FROM accounts
                    WHERE \(database.predicateForLiveRows(columns: columns))
                    ORDER BY lower(\(name)), id
                    """
            ).compactMap { row in
                guard let id = SQLiteValueCoercion.lenientString(row["id"]), !id.isEmpty else { return nil }
                let rawName = SQLiteValueCoercion.lenientString(row["name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                return ReportExplorerAccountFilterOption(
                    id: id,
                    name: rawName.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Account",
                    isOffBudget: SQLiteValueCoercion.lenientBool(row["offbudget"]),
                    isClosed: SQLiteValueCoercion.lenientBool(row["closed"])
                )
            }
        } else {
            accounts = []
        }

        let categories: [ReportExplorerCategoryFilterOption]
        if try database.tableExists("categories", db: db) {
            let columns = try database.columnSet(for: "categories", db: db)
            let nameExpression = columns.contains("name") ? "c.name" : "c.id"
            let hiddenExpression = columns.contains("hidden") ? "c.hidden" : "0"
            let incomeExpression = columns.contains("is_income") ? "c.is_income" : "0"
            let groupIDExpression = columns.contains("cat_group")
                ? "c.cat_group"
                : columns.contains("group_id") ? "c.group_id" : "NULL"
            let hasGroups = try database.tableExists("category_groups", db: db)
            let groupJoin: String
            let groupName: String
            let groupHidden: String
            if hasGroups {
                let groupColumns = try database.columnSet(for: "category_groups", db: db)
                groupJoin = "LEFT JOIN category_groups g ON g.id = \(groupIDExpression)"
                groupName = groupColumns.contains("name") ? "g.name" : "g.id"
                groupHidden = groupColumns.contains("hidden") ? "g.hidden" : "0"
            } else {
                groupJoin = ""
                groupName = "''"
                groupHidden = "0"
            }
            categories = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.id AS id,
                           \(nameExpression) AS name,
                           \(groupIDExpression) AS group_id,
                           \(groupName) AS group_name,
                           CASE WHEN COALESCE(\(incomeExpression), 0) != 0 THEN 1 ELSE 0 END AS is_income,
                           CASE WHEN COALESCE(\(hiddenExpression), 0) != 0
                                      OR COALESCE(\(groupHidden), 0) != 0 THEN 1 ELSE 0 END AS hidden
                    FROM categories c
                    \(groupJoin)
                    WHERE \(database.predicateForLiveRows(columns: columns, tableAlias: "c"))
                    ORDER BY lower(\(groupName)), lower(\(nameExpression)), c.id
                    """
            ).compactMap { row in
                guard let id = SQLiteValueCoercion.lenientString(row["id"]), !id.isEmpty else { return nil }
                let rawName = SQLiteValueCoercion.lenientString(row["name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawGroupName = SQLiteValueCoercion.lenientString(row["group_name"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return ReportExplorerCategoryFilterOption(
                    id: id,
                    name: rawName.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Category",
                    groupID: SQLiteValueCoercion.lenientString(row["group_id"]),
                    groupName: rawGroupName.flatMap { $0.isEmpty ? nil : $0 } ?? "Categories",
                    isIncome: SQLiteValueCoercion.lenientBool(row["is_income"]),
                    isHidden: SQLiteValueCoercion.lenientBool(row["hidden"])
                )
            }
        } else {
            categories = []
        }
        return ReportExplorerFilterCatalog(accounts: accounts, categories: categories)
    }
}
