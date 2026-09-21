import Foundation
import GRDB

extension BudgetDatabase {

    func fetchBudgetMonth(month: String) throws -> BudgetMonth {
        try queue.read { db in try fetchBudgetMonth(month: month, db: db) }
    }

    func fetchBudgetSnapshot(month: String, now: Date = Date()) throws -> BudgetFinancialSnapshot {
        try queue.read { db in
            let value = try LaunchSignpost.measureSync(LaunchStage.budgetMonthCalculation) {
                try fetchBudgetMonth(month: month, db: db)
            }
            let discovered = try LaunchSignpost.measureSync(LaunchStage.budgetAvailableMonths) {
                try fetchAvailableMonths(db: db)
            }
            let months = value.trackingSummary == nil ? discovered
                : Array(Set(discovered + [month, YearMonth(date: now).rawValue])).sorted()
            let currency = try LaunchSignpost.measureSync(LaunchStage.budgetSnapshotCurrency) {
                try budgetCurrency(db: db)
            }
            return BudgetFinancialSnapshot(
                modeIdentity: try budgetModeIdentity(db: db),
                month: value,
                currency: currency,
                availableMonths: months
            )
        }
    }

    private func fetchBudgetMonth(month: String, db: Database) throws -> BudgetMonth {
        let table = try budgetTable(db: db)
        let categoryValues = try categoryValues(through: month, db: db)
        let userNoteIDs = try allUserNoteIDs(db: db)
        let groups = try fetchCategoryGroups(
            categoryValues: categoryValues,
            userNoteIDs: userNoteIDs,
            db: db
        )
        let totals = try BudgetFinancialCalculation.totals(groups: groups, table: table)
        let availability = table == .tracking ? (toBudget: 0, holdForNextMonth: 0)
            : try envelopeAvailability(month: month, totalBalance: totals.balance, db: db)

        return BudgetMonth(
            month: month,
            incomeAvailable: availability.toBudget,
            lastMonthOverspent: 0,
            forNextMonth: availability.holdForNextMonth,
            totalBudgeted: totals.budgeted,
            toBudget: availability.toBudget,
            fromLastMonth: 0,
            totalIncome: totals.income,
            totalSpent: totals.spent,
            totalBalance: totals.balance,
            categoryGroups: groups,
            hasUserNote: userNoteIDs.contains("budget-\(month)"),
            trackingSummary: totals.tracking
        )
    }

    /// Envelope spreadsheet `to-budget`: on-budget funds minus leftover minus this month's hold.
    func envelopeAvailability(
        month: String,
        totalBalance: Int,
        db: Database
    ) throws -> (toBudget: Int, holdForNextMonth: Int) {
        let onBudgetBalance = try onBudgetAccountBalance(through: month, db: db)
        let uncategorizedActivity = try uncategorizedOnBudgetActivity(through: month, db: db)
        let holdForNextMonth = try envelopeHold(month: month, db: db)
        let toBudget = (onBudgetBalance - uncategorizedActivity) - totalBalance - holdForNextMonth
        return (toBudget, holdForNextMonth)
    }

    func envelopeToBudget(month: String, db: Database) throws -> Int {
        let categoryValues = try categoryValues(through: month, db: db)
        let groups = try fetchCategoryGroups(categoryValues: categoryValues, db: db)
        let totalBalance = groups.filter { !$0.isIncome }.reduce(0) { $0 + $1.balance }
        return try envelopeAvailability(
            month: month,
            totalBalance: totalBalance,
            db: db
        ).toBudget
    }

    /// Tracking spreadsheet `total-saved`: budgeted income minus budgeted expenses.
    /// Hidden expense groups and hidden categories are omitted, matching Actual's
    /// tracking sheet (`createSummary` / `group-budget`).
    func trackingTotalSaved(month: String, db: Database) throws -> Int {
        let categoryValues = try categoryValues(through: month, db: db)
        let groups = try fetchCategoryGroups(categoryValues: categoryValues, db: db)
        return try BudgetFinancialCalculation.totals(groups: groups, table: .tracking)
            .tracking?.plannedSavings ?? 0
    }

    func accountBalances() throws -> [String: Int] {
        try queue.read { db in
            guard try tableExists("transactions", db: db) else {
                return [:]
            }

            let columns = try columnSet(for: "transactions", db: db)
            let split = transactionSplitQueryExpressions(columns: columns)
            let sql = """
                SELECT \(split.qualifiedAccount) AS account_id, SUM(\(split.qualifiedAmount)) AS balance
                FROM transactions t
                \(split.parentJoin())
                WHERE \(split.liveInlinePredicate())
                GROUP BY \(split.qualifiedAccount)
                """
            let rows = try Row.fetchAll(db, sql: sql)
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let accountID = row["account_id"] as String? else {
                    return nil
                }
                return (accountID, row["balance"] ?? 0)
            })
        }
    }

    func onBudgetAccountBalance(through month: String, db: Database) throws -> Int {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return 0
        }

        let columns = try columnSet(for: "transactions", db: db)
        let split = transactionSplitQueryExpressions(columns: columns)
        let budgetMonth = normalizedMonthExpression(split.qualifiedDate)
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT SUM(\(split.qualifiedAmount)) AS balance
                FROM transactions t
                LEFT JOIN accounts a ON a.id = \(split.qualifiedAccount)
                \(split.parentJoin())
                WHERE \(split.liveInlinePredicate())
                  AND a.offbudget = 0
                  AND \(budgetMonth) <= ?
                """,
            arguments: [month]
        )
        return row?["balance"] ?? 0
    }

    func uncategorizedOnBudgetActivity(through month: String, db: Database) throws -> Int {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return 0
        }

        let columns = try columnSet(for: "transactions", db: db)
        let split = transactionSplitQueryExpressions(columns: columns)
        let budgetMonth = normalizedMonthExpression(split.qualifiedDate)
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT SUM(\(split.qualifiedAmount)) AS amount
                FROM transactions t
                LEFT JOIN accounts a ON a.id = \(split.qualifiedAccount)
                \(split.parentJoin())
                WHERE \(split.liveInlinePredicate())
                  AND (\(split.qualifiedCategory) IS NULL OR \(split.qualifiedCategory) = '')
                  AND a.offbudget = 0
                  AND \(budgetMonth) <= ?
                """,
            arguments: [month]
        )
        return row?["amount"] ?? 0
    }

    func fetchCategoryGroups(
        categoryValues: [String: BudgetCategoryValue],
        userNoteIDs: Set<String> = [],
        db: Database
    ) throws -> [BudgetMonthCategoryGroup] {
        guard try tableExists("category_groups", db: db) else {
            return []
        }

        let table = try budgetTable(db: db)
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

        let categoriesByGroup = try fetchBudgetCategoriesByGroup(
            categoryValues: categoryValues,
            userNoteIDs: userNoteIDs,
            db: db
        )
        var result: [BudgetMonthCategoryGroup] = []
        for groupRow in groupRows {
            let groupID: String = groupRow["id"] ?? ""
            let categories = categoriesByGroup[groupID] ?? []
            let included = BudgetFinancialCalculation.includedCategories(categories, table: table)
            result.append(BudgetMonthCategoryGroup(
                id: groupID,
                name: groupRow["name"] ?? "",
                isIncome: flexibleBool(groupRow["is_income"]),
                hidden: flexibleBool(groupRow["hidden"]),
                budgeted: try BudgetFinancialCalculation.sum(included.map(\.budgeted), table: table),
                spent: try BudgetFinancialCalculation.sum(included.map(\.spent), table: table),
                balance: try BudgetFinancialCalculation.sum(included.map(\.balance), table: table),
                categories: categories,
                hasUserNote: userNoteIDs.contains(groupID)
            ))
        }
        return result
    }

    private func fetchBudgetCategoriesByGroup(
        categoryValues: [String: BudgetCategoryValue],
        userNoteIDs: Set<String> = [],
        db: Database
    ) throws -> [String: [BudgetMonthCategory]] {
        guard try tableExists("categories", db: db) else {
            return [:]
        }

        let categoryColumns = try columnSet(for: "categories", db: db)
        let groupColumn = column("cat_group", fallback: column("group_id", fallback: "NULL", columns: categoryColumns), columns: categoryColumns)
        let categoryHidden = column("hidden", fallback: "0", columns: categoryColumns)
        let categoryIncome = column("is_income", fallback: "0", columns: categoryColumns)
        let goalDefinition = column("goal_def", fallback: "NULL", columns: categoryColumns)
        let categoryOrder = categoryColumns.contains("sort_order") ? "sort_order, lower(name)" : "lower(name)"
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, \(categoryIncome) AS is_income, \(categoryHidden) AS hidden,
                       \(groupColumn) AS group_id, \(goalDefinition) AS goal_def
                FROM categories
                WHERE \(predicateForLiveRows(columns: categoryColumns))
                ORDER BY \(categoryOrder)
                """
        )

        var result: [String: [BudgetMonthCategory]] = [:]
        for row in rows {
            guard let groupID: String = row["group_id"] else { continue }
            let id: String = row["id"] ?? ""
            let values = categoryValues[id] ?? BudgetCategoryValue()
            result[groupID, default: []].append(BudgetMonthCategory(
                id: id,
                name: row["name"] ?? "",
                isIncome: flexibleBool(row["is_income"]),
                hidden: flexibleBool(row["hidden"]),
                groupID: row["group_id"] ?? groupID,
                budgeted: values.budgeted,
                spent: values.spent,
                balance: values.balance,
                carryover: values.carryover,
                hasTemplateDefinition: hasStoredTemplateDefinition(row["goal_def"]),
                hasUserNote: userNoteIDs.contains(id)
            ))
        }
        return result
    }

    func hasStoredTemplateDefinition(_ rawValue: String?) -> Bool {
        switch BudgetTemplateDefinition.parseEntries(from: rawValue) {
        case .success(let definitions):
            return !definitions.isEmpty
        case .failure:
            // Keep malformed stored definitions visible so Apply Template can
            // surface the existing fail-closed validation error.
            return true
        }
    }

    func categoryValues(through month: String, db: Database) throws -> [String: BudgetCategoryValue] {
        let table = try budgetTable(db: db)
        let incomeByCategory = table == .tracking ? try templateCategoryIsIncomeByID(db: db) : [:]
        let budgetedByMonth = try categoryBudgetsByMonth(db: db)
        let spentByMonth = try categorySpendingByMonth(db: db)
        guard canonicalMonthID(month) == month else {
            throw LocalFirstError.invalidLocalWrite("invalid budget month")
        }
        let targetMonthInt = monthInt(month)
        let earliestMonthInt = Array(Set(budgetedByMonth.keys).union(spentByMonth.keys))
            .compactMap { canonicalMonthID($0).map(monthInt) }
            .filter { $0 <= targetMonthInt }
            .min() ?? targetMonthInt

        var valuesByCategory: [String: BudgetCategoryValue] = [:]

        var monthCursor = earliestMonthInt
        while monthCursor <= targetMonthInt {
            let budgetMonth = monthID(monthCursor)
            let budgeted = budgetedByMonth[budgetMonth] ?? [:]
            let spent = spentByMonth[budgetMonth] ?? [:]
            let categoryIDs = Set(budgeted.keys).union(spent.keys).union(valuesByCategory.keys)
            var nextValues: [String: BudgetCategoryValue] = [:]

            for categoryID in categoryIDs {
                let budget = budgeted[categoryID] ?? (budgeted: 0, carryover: false)
                let spentAmount = spent[categoryID] ?? 0
                let value = try BudgetFinancialCalculation.category(
                    table: table, isIncome: incomeByCategory[categoryID] ?? false,
                    budgeted: budget.budgeted, activity: spentAmount, carryover: budget.carryover,
                    previous: valuesByCategory[categoryID] ?? BudgetCategoryValue()
                )
                nextValues[categoryID] = value
            }

            valuesByCategory = nextValues
            monthCursor = nextMonth(after: monthCursor)
        }

        return valuesByCategory
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
                    budgeted: row["amount"] ?? 0,
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
                budgeted: row["amount"] ?? 0,
                carryover: flexibleBool(row["carryover"])
            )
        }
    }

    func categorySpending(month: String, db: Database) throws -> [String: Int] {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "transactions", db: db)
        let split = transactionSplitQueryExpressions(columns: columns)
        let transferColumn = try categoryMappingTransferColumn(db: db)
        let categoryMappingJoin = transferColumn == nil
            ? ""
            : "LEFT JOIN category_mapping cm ON cm.id = \(split.qualifiedCategory)"
        let mappedCategory = transferColumn.map {
            "COALESCE(cm.\(quotedIdentifier($0)), \(split.qualifiedCategory))"
        } ?? split.qualifiedCategory
        let budgetMonth = normalizedMonthExpression(split.qualifiedDate)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(mappedCategory) AS category_id, SUM(\(split.qualifiedAmount)) AS amount
                FROM transactions t
                \(categoryMappingJoin)
                LEFT JOIN accounts a ON a.id = \(split.qualifiedAccount)
                \(split.parentJoin())
                WHERE \(split.liveInlinePredicate())
                  AND \(split.qualifiedCategory) IS NOT NULL
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
            return (categoryID, row["amount"] ?? 0)
        })
    }

    func categorySpendingByMonth(db: Database) throws -> [String: [String: Int]] {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "transactions", db: db)
        let split = transactionSplitQueryExpressions(columns: columns)
        let transferColumn = try categoryMappingTransferColumn(db: db)
        let categoryMappingJoin = transferColumn == nil
            ? ""
            : "LEFT JOIN category_mapping cm ON cm.id = \(split.qualifiedCategory)"
        let mappedCategory = transferColumn.map {
            "COALESCE(cm.\(quotedIdentifier($0)), \(split.qualifiedCategory))"
        } ?? split.qualifiedCategory
        let budgetMonth = normalizedMonthExpression(split.qualifiedDate)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(budgetMonth) AS month, \(mappedCategory) AS category_id, SUM(\(split.qualifiedAmount)) AS amount
                FROM transactions t
                \(categoryMappingJoin)
                LEFT JOIN accounts a ON a.id = \(split.qualifiedAccount)
                \(split.parentJoin())
                WHERE \(split.liveInlinePredicate())
                  AND \(split.qualifiedCategory) IS NOT NULL
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
            result[month, default: [:]][categoryID] = row["amount"] ?? 0
        }
    }
}
