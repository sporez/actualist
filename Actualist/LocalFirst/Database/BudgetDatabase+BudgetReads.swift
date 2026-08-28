import Foundation
import GRDB

extension BudgetDatabase {

    func fetchBudgetMonth(month: String) throws -> BudgetMonth {
        try queue.read { db in
            let categoryValues = try envelopeCategoryValues(through: month, db: db)
            let groups = try fetchCategoryGroups(categoryValues: categoryValues, db: db)
            let expenseGroups = groups.filter { !$0.isIncome }
            let incomeGroups = groups.filter { $0.isIncome }
            let totalBudgeted = expenseGroups.reduce(0) { $0 + $1.budgeted }
            let totalSpent = expenseGroups.reduce(0) { $0 + $1.spent }
            let totalBalance = expenseGroups.reduce(0) { $0 + $1.balance }
            let totalIncome = incomeGroups.reduce(0) { $0 + $1.spent }
            // Actual excludes uncategorized rows from To Budget until they are categorized.
            // A hold for next month (explicit or inferred) also comes out of this month.
            let onBudgetBalance = try onBudgetAccountBalance(through: month, db: db)
            let uncategorizedActivity = try uncategorizedOnBudgetActivity(through: month, db: db)
            let holdForNextMonth = try envelopeHold(month: month, db: db)
            let toBudget = (onBudgetBalance - uncategorizedActivity) - totalBalance - holdForNextMonth

            return BudgetMonth(
                month: month,
                incomeAvailable: toBudget,
                lastMonthOverspent: 0,
                forNextMonth: holdForNextMonth,
                totalBudgeted: totalBudgeted,
                toBudget: toBudget,
                fromLastMonth: 0,
                totalIncome: totalIncome,
                totalSpent: totalSpent,
                totalBalance: totalBalance,
                categoryGroups: groups
            )
        }
    }

    func accountBalances() throws -> [String: Int] {
        try queue.read { db in
            guard try tableExists("transactions", db: db) else {
                return [:]
            }

            let columns = try columnSet(for: "transactions", db: db)
            let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
            let amount = column("amount", fallback: "0", columns: columns)
            let parentPredicate = parentTransactionPredicate(columns: columns)
            let sql = """
                SELECT \(account) AS account_id, SUM(\(amount)) AS balance
                FROM transactions
                WHERE \(predicateForLiveRows(columns: columns)) AND \(parentPredicate)
                GROUP BY \(account)
                """
            let rows = try Row.fetchAll(db, sql: sql)
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let accountID = row["account_id"] as String? else {
                    return nil
                }
                return (accountID, actualAmountToMinorUnits(row["balance"] ?? 0))
            })
        }
    }

    func onBudgetAccountBalance(through month: String, db: Database) throws -> Int {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return 0
        }

        let columns = try columnSet(for: "transactions", db: db)
        let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        let date = column("date", fallback: "NULL", columns: columns)
        let parentID = column("parent_id", fallback: "NULL", columns: columns)
        let isParent = column("isParent", fallback: column("is_parent", fallback: "0", columns: columns), columns: columns)
        let budgetMonth = normalizedMonthExpression("t.\(date)")
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT SUM(t.\(amount)) AS balance
                FROM transactions t
                LEFT JOIN accounts a ON a.id = t.\(account)
                LEFT JOIN transactions p ON p.id = t.\(parentID)
                WHERE \(predicateForLiveRows(columns: columns, tableAlias: "t"))
                  AND (t.\(parentID) IS NULL OR p.tombstone = 0 OR p.tombstone IS NULL)
                  AND (t.\(isParent) = 0 OR t.\(isParent) IS NULL)
                  AND a.offbudget = 0
                  AND \(budgetMonth) <= ?
                """,
            arguments: [month]
        )
        return actualAmountToMinorUnits(row?["balance"] ?? 0)
    }

    func uncategorizedOnBudgetActivity(through month: String, db: Database) throws -> Int {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return 0
        }

        let columns = try columnSet(for: "transactions", db: db)
        let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
        let category = column("category", fallback: "NULL", columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        let date = column("date", fallback: "NULL", columns: columns)
        let parentID = column("parent_id", fallback: "NULL", columns: columns)
        let isParent = column("isParent", fallback: column("is_parent", fallback: "0", columns: columns), columns: columns)
        let budgetMonth = normalizedMonthExpression("t.\(date)")
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT SUM(t.\(amount)) AS amount
                FROM transactions t
                LEFT JOIN accounts a ON a.id = t.\(account)
                LEFT JOIN transactions p ON p.id = t.\(parentID)
                WHERE \(predicateForLiveRows(columns: columns, tableAlias: "t"))
                  AND (t.\(parentID) IS NULL OR p.tombstone = 0 OR p.tombstone IS NULL)
                  AND (t.\(isParent) = 0 OR t.\(isParent) IS NULL)
                  AND (t.\(category) IS NULL OR t.\(category) = '')
                  AND a.offbudget = 0
                  AND \(budgetMonth) <= ?
                """,
            arguments: [month]
        )
        return actualAmountToMinorUnits(row?["amount"] ?? 0)
    }

    func fetchCategoryGroups(
        categoryValues: [String: EnvelopeCategoryValue],
        db: Database
    ) throws -> [BudgetMonthCategoryGroup] {
        guard try tableExists("category_groups", db: db) else {
            return []
        }

        let groupColumns = try columnSet(for: "category_groups", db: db)
        let groupHidden = column("hidden", fallback: "0", columns: groupColumns)
        let groupIncome = column("is_income", fallback: "0", columns: groupColumns)
        let groupOrder = groupColumns.contains("sort_order") ? "sort_order, lower(name)" : "lower(name)"
        let groupRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, \(groupIncome) AS is_income, \(groupHidden) AS hidden
                FROM category_groups
                WHERE \(predicateForLiveRows(columns: groupColumns))
                ORDER BY \(groupOrder)
                """
        )

        return try groupRows.map { groupRow in
            let groupID: String = groupRow["id"] ?? ""
            let categories = try fetchBudgetCategories(groupID: groupID, categoryValues: categoryValues, db: db)
            return BudgetMonthCategoryGroup(
                id: groupID,
                name: groupRow["name"] ?? "",
                isIncome: flexibleBool(groupRow["is_income"]),
                hidden: flexibleBool(groupRow["hidden"]),
                budgeted: categories.reduce(0) { $0 + $1.budgeted },
                spent: categories.reduce(0) { $0 + $1.spent },
                balance: categories.reduce(0) { $0 + $1.balance },
                categories: categories
            )
        }
    }

    func fetchBudgetCategories(
        groupID: String,
        categoryValues: [String: EnvelopeCategoryValue],
        db: Database
    ) throws -> [BudgetMonthCategory] {
        guard try tableExists("categories", db: db) else {
            return []
        }

        let categoryColumns = try columnSet(for: "categories", db: db)
        let groupColumn = column("cat_group", fallback: column("group_id", fallback: "NULL", columns: categoryColumns), columns: categoryColumns)
        let categoryHidden = column("hidden", fallback: "0", columns: categoryColumns)
        let categoryIncome = column("is_income", fallback: "0", columns: categoryColumns)
        let categoryOrder = categoryColumns.contains("sort_order") ? "sort_order, lower(name)" : "lower(name)"
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, \(categoryIncome) AS is_income, \(categoryHidden) AS hidden, \(groupColumn) AS group_id
                FROM categories
                WHERE \(predicateForLiveRows(columns: categoryColumns)) AND \(groupColumn) = ?
                ORDER BY \(categoryOrder)
                """,
            arguments: [groupID]
        )

        return rows.map { row in
            let id: String = row["id"] ?? ""
            let values = categoryValues[id] ?? EnvelopeCategoryValue()
            return BudgetMonthCategory(
                id: id,
                name: row["name"] ?? "",
                isIncome: flexibleBool(row["is_income"]),
                hidden: flexibleBool(row["hidden"]),
                groupID: row["group_id"] ?? groupID,
                budgeted: values.budgeted,
                spent: values.spent,
                balance: values.balance,
                carryover: values.carryover
            )
        }
    }

    func envelopeCategoryValues(through month: String, db: Database) throws -> [String: EnvelopeCategoryValue] {
        let budgetedByMonth = try categoryBudgetsByMonth(db: db)
        let spentByMonth = try categorySpendingByMonth(db: db)
        let targetMonthInt = monthInt(month)
        let earliestMonthInt = Array(Set(budgetedByMonth.keys).union(spentByMonth.keys))
            .compactMap(monthInt)
            .filter { $0 <= targetMonthInt }
            .min() ?? targetMonthInt

        var previousBalanceByCategory: [String: Int] = [:]
        var previousCarryoverByCategory: [String: Bool] = [:]
        var targetValues: [String: EnvelopeCategoryValue] = [:]

        var monthCursor = earliestMonthInt
        while monthCursor <= targetMonthInt {
            let budgetMonth = monthID(monthCursor)
            let budgeted = budgetedByMonth[budgetMonth] ?? [:]
            let spent = spentByMonth[budgetMonth] ?? [:]
            let categoryIDs = Set(budgeted.keys).union(spent.keys).union(previousBalanceByCategory.keys)
            var nextBalanceByCategory: [String: Int] = [:]
            var nextCarryoverByCategory: [String: Bool] = [:]

            for categoryID in categoryIDs {
                let budget = budgeted[categoryID] ?? (budgeted: 0, carryover: false)
                let spentAmount = spent[categoryID] ?? 0
                let previousBalance = previousBalanceByCategory[categoryID] ?? 0
                let previousContribution = previousCarryoverByCategory[categoryID] == true
                    ? previousBalance
                    : max(0, previousBalance)
                let balance = budget.budgeted + spentAmount + previousContribution
                nextBalanceByCategory[categoryID] = balance
                nextCarryoverByCategory[categoryID] = budget.carryover

                if budgetMonth == month {
                    targetValues[categoryID] = EnvelopeCategoryValue(
                        budgeted: budget.budgeted,
                        spent: spentAmount,
                        balance: balance,
                        carryover: budget.carryover
                    )
                }
            }

            previousBalanceByCategory = nextBalanceByCategory
            previousCarryoverByCategory = nextCarryoverByCategory
            monthCursor = nextMonth(after: monthCursor)
        }

        return targetValues
    }

    func categoryBudgetSource(db: Database) throws -> (table: BudgetTable, columns: Set<String>)? {
        let table = try budgetTable(db: db)
        guard try tableExists(table.rawValue, db: db) else {
            return nil
        }
        return (table, try columnSet(for: table.rawValue, db: db))
    }

    func categoryBudgets(month: String, db: Database) throws -> [String: (budgeted: Int, carryover: Bool)] {
        guard let source = try categoryBudgetSource(db: db) else {
            return [:]
        }
        let category = column("category", fallback: "NULL", columns: source.columns)
        let amount = column("amount", fallback: "0", columns: source.columns)
        let carryover = column("carryover", fallback: "0", columns: source.columns)
        let budgetMonth = normalizedMonthExpression("month")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(category) AS category_id, \(amount) AS amount, \(carryover) AS carryover
                FROM \(quotedIdentifier(source.table.rawValue))
                WHERE \(budgetMonth) = ?
                """,
            arguments: [month]
        )
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let categoryID = row["category_id"] as String? else {
                return nil
            }
            return (
                categoryID,
                (
                    budgeted: actualAmountToMinorUnits(row["amount"] ?? 0),
                    carryover: flexibleBool(row["carryover"])
                )
            )
        })
    }

    func categoryBudgetsByMonth(db: Database) throws -> [String: [String: (budgeted: Int, carryover: Bool)]] {
        guard let source = try categoryBudgetSource(db: db) else {
            return [:]
        }
        let category = column("category", fallback: "NULL", columns: source.columns)
        let amount = column("amount", fallback: "0", columns: source.columns)
        let carryover = column("carryover", fallback: "0", columns: source.columns)
        let budgetMonth = normalizedMonthExpression("month")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(budgetMonth) AS month, \(category) AS category_id, \(amount) AS amount, \(carryover) AS carryover
                FROM \(quotedIdentifier(source.table.rawValue))
                WHERE month IS NOT NULL
                """
        )
        return rows.reduce(into: [:]) { result, row in
            guard
                let month = flexibleString(row["month"]),
                let categoryID = row["category_id"] as String?
            else {
                return
            }
            result[month, default: [:]][categoryID] = (
                budgeted: actualAmountToMinorUnits(row["amount"] ?? 0),
                carryover: flexibleBool(row["carryover"])
            )
        }
    }

    func categorySpending(month: String, db: Database) throws -> [String: Int] {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "transactions", db: db)
        let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
        let category = column("category", fallback: "NULL", columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        let date = column("date", fallback: "NULL", columns: columns)
        let parentID = column("parent_id", fallback: "NULL", columns: columns)
        let isParent = column("isParent", fallback: column("is_parent", fallback: "0", columns: columns), columns: columns)
        let categoryMappingJoin = try tableExists("category_mapping", db: db)
            ? "LEFT JOIN category_mapping cm ON cm.id = t.\(category)"
            : ""
        let mappedCategory = try tableExists("category_mapping", db: db)
            ? "COALESCE(cm.transferId, t.\(category))"
            : "t.\(category)"
        let budgetMonth = normalizedMonthExpression("t.\(date)")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(mappedCategory) AS category_id, SUM(t.\(amount)) AS amount
                FROM transactions t
                \(categoryMappingJoin)
                LEFT JOIN accounts a ON a.id = t.\(account)
                LEFT JOIN transactions p ON p.id = t.\(parentID)
                WHERE \(predicateForLiveRows(columns: columns, tableAlias: "t"))
                  AND (t.\(parentID) IS NULL OR p.tombstone = 0 OR p.tombstone IS NULL)
                  AND (t.\(isParent) = 0 OR t.\(isParent) IS NULL)
                  AND t.\(category) IS NOT NULL
                  AND a.offbudget = 0
                  AND \(budgetMonth) = ?
                GROUP BY \(mappedCategory)
                """,
            arguments: [month]
        )
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let categoryID = row["category_id"] as String? else {
                return nil
            }
            return (categoryID, actualAmountToMinorUnits(row["amount"] ?? 0))
        })
    }

    func categorySpendingByMonth(db: Database) throws -> [String: [String: Int]] {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "transactions", db: db)
        let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
        let category = column("category", fallback: "NULL", columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        let date = column("date", fallback: "NULL", columns: columns)
        let parentID = column("parent_id", fallback: "NULL", columns: columns)
        let isParent = column("isParent", fallback: column("is_parent", fallback: "0", columns: columns), columns: columns)
        let categoryMappingJoin = try tableExists("category_mapping", db: db)
            ? "LEFT JOIN category_mapping cm ON cm.id = t.\(category)"
            : ""
        let mappedCategory = try tableExists("category_mapping", db: db)
            ? "COALESCE(cm.transferId, t.\(category))"
            : "t.\(category)"
        let budgetMonth = normalizedMonthExpression("t.\(date)")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(budgetMonth) AS month, \(mappedCategory) AS category_id, SUM(t.\(amount)) AS amount
                FROM transactions t
                \(categoryMappingJoin)
                LEFT JOIN accounts a ON a.id = t.\(account)
                LEFT JOIN transactions p ON p.id = t.\(parentID)
                WHERE \(predicateForLiveRows(columns: columns, tableAlias: "t"))
                  AND (t.\(parentID) IS NULL OR p.tombstone = 0 OR p.tombstone IS NULL)
                  AND (t.\(isParent) = 0 OR t.\(isParent) IS NULL)
                  AND t.\(category) IS NOT NULL
                  AND a.offbudget = 0
                GROUP BY \(budgetMonth), \(mappedCategory)
                """
        )
        return rows.reduce(into: [:]) { result, row in
            guard
                let month = flexibleString(row["month"]),
                let categoryID = row["category_id"] as String?
            else {
                return
            }
            result[month, default: [:]][categoryID] = actualAmountToMinorUnits(row["amount"] ?? 0)
        }
    }

    func transactionBudgetSource(db: Database) throws -> TransactionBudgetSource {
        if try tableExists("v_transactions_internal_alive", db: db) {
            return TransactionBudgetSource(
                tableExists: true,
                table: "v_transactions_internal_alive",
                account: "account",
                category: "t.category",
                amount: "t.amount",
                month: normalizedMonthExpression("t.date"),
                livePredicate: "1 = 1"
            )
        }

        guard try tableExists("transactions", db: db) else {
            return TransactionBudgetSource(
                tableExists: false,
                table: "transactions",
                account: "acct",
                category: "category",
                amount: "amount",
                month: normalizedMonthExpression("date"),
                livePredicate: "1 = 0"
            )
        }

        let columns = try columnSet(for: "transactions", db: db)
        let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
        let category = column("category", fallback: "NULL", columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        return TransactionBudgetSource(
            tableExists: true,
            table: "transactions",
            account: account,
            category: "t.\(category)",
            amount: "t.\(amount)",
            month: normalizedMonthExpression("t.date"),
            livePredicate: "\(predicateForLiveRows(columns: columns, tableAlias: "t")) AND \(parentTransactionPredicate(columns: columns, tableAlias: "t"))"
        )
    }
}
