import Foundation
import GRDB

enum BudgetMonthSQL {
    static func fetchBudgetMonth(month: String, in database: isolated BudgetDatabase) throws -> BudgetMonth {
        try database.queue.read { db in try fetchBudgetMonth(month: month, in: database, db: db) }
    }

    static func fetchBudgetSnapshot(month: String, now: Date = Date(), in database: isolated BudgetDatabase) throws -> BudgetFinancialSnapshot {
        try database.queue.read { db in
            let value = try LaunchSignpost.measureSync(LaunchStage.budgetMonthCalculation) {
                try fetchBudgetMonth(month: month, in: database, db: db)
            }
            let discovered = try LaunchSignpost.measureSync(LaunchStage.budgetAvailableMonths) {
                try fetchAvailableMonths(in: database, db: db)
            }
            let months = value.trackingSummary == nil ? discovered
                : Array(Set(discovered + [month, YearMonth(date: now).rawValue])).sorted()
            let currency = try LaunchSignpost.measureSync(LaunchStage.budgetSnapshotCurrency) {
                try BudgetCurrencySQL.budgetCurrency(in: database, db: db)
            }
            return BudgetFinancialSnapshot(
                modeIdentity: try database.budgetModeIdentity(db: db),
                month: value,
                currency: currency,
                availableMonths: months
            )
        }
    }

    static func fetchBudgetMonth(month: String, in database: isolated BudgetDatabase, db: Database) throws -> BudgetMonth {
        let table = try database.budgetTable(db: db)
        let (categoryValues, previousValues) = try BudgetCategoryValueSQL.categoryValuesWithPrevious(through: month, in: database, db: db)
        let userNoteIDs = try database.userNoteIDs(inMonth: month, db: db)
        let groups = try fetchCategoryGroups(
            categoryValues: categoryValues,
            userNoteIDs: userNoteIDs,
            in: database,
            db: db
        )
        let totals = try BudgetFinancialCalculation.totals(groups: groups, table: table)
        let availability = table == .tracking ? (toBudget: 0, holdForNextMonth: 0)
            : try envelopeAvailability(month: month, totalBalance: totals.balance, in: database, db: db)
        // Tracking budgets have no To Budget, From Last Month or Available Funds.
        let carryIn = table == .tracking ? nil : try envelopeCarryIn(
            month: month, groups: groups, previousValues: previousValues, in: database, db: db
        )
        let fromLastMonth = carryIn?.fromLastMonth ?? 0

        return BudgetMonth(
            month: month,
            incomeAvailable: table == .tracking ? 0
                : try BudgetTemplateEngine.checkedAdd(totals.income, fromLastMonth),
            lastMonthOverspent: carryIn?.lastMonthOverspent ?? 0,
            forNextMonth: availability.holdForNextMonth,
            totalBudgeted: totals.budgeted,
            toBudget: availability.toBudget,
            fromLastMonth: fromLastMonth,
            totalIncome: totals.income,
            totalSpent: totals.spent,
            totalBalance: totals.balance,
            categoryGroups: groups,
            hasUserNote: userNoteIDs.contains("budget-\(month)"),
            trackingSummary: totals.tracking
        )
    }

    /// Envelope spreadsheet `to-budget`: on-budget funds minus leftover minus this month's hold.
    private static func envelopeAvailability(
        month: String,
        totalBalance: Int,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> (toBudget: Int, holdForNextMonth: Int) {
        let onBudgetBalance = try onBudgetAccountBalance(through: month, in: database, db: db)
        let uncategorizedActivity = try uncategorizedOnBudgetActivity(through: month, in: database, db: db)
        let holdForNextMonth = try BudgetHoldSQL.envelopeHold(month: month, in: database, db: db)
        let toBudget = (onBudgetBalance - uncategorizedActivity) - totalBalance - holdForNextMonth
        return (toBudget, holdForNextMonth)
    }

    static func envelopeToBudget(month: String, history: TemplateHistory? = nil, in database: isolated BudgetDatabase, db: Database) throws -> Int {
        let categoryValues = try BudgetCategoryValueSQL.categoryValues(through: month, history: history, in: database, db: db)
        let groups = try fetchCategoryGroups(categoryValues: categoryValues, in: database, db: db)
        let totalBalance = groups.filter { !$0.isIncome }.reduce(0) { $0 + $1.balance }
        return try envelopeAvailability(
            month: month,
            totalBalance: totalBalance,
            in: database,
            db: db
        ).toBudget
    }

    /// Tracking spreadsheet `total-saved`: budgeted income minus budgeted expenses.
    /// Hidden expense groups and hidden categories are omitted, matching Actual's
    /// tracking sheet (`createSummary` / `group-budget`).
    static func trackingTotalSaved(month: String, history: TemplateHistory? = nil, in database: isolated BudgetDatabase, db: Database) throws -> Int {
        let categoryValues = try BudgetCategoryValueSQL.categoryValues(through: month, history: history, in: database, db: db)
        let groups = try fetchCategoryGroups(categoryValues: categoryValues, in: database, db: db)
        return try BudgetFinancialCalculation.totals(groups: groups, table: .tracking)
            .tracking?.plannedSavings ?? 0
    }

    private static func onBudgetAccountBalance(through month: String, in database: isolated BudgetDatabase, db: Database) throws -> Int {
        guard try database.tableExists("transactions", db: db), try database.tableExists("accounts", db: db) else {
            return 0
        }

        let columns = try database.columnSet(for: "transactions", db: db)
        let split = TransactionSplitQueryExpressions(columns: columns)
        let budgetMonth = database.normalizedMonthExpression(split.qualifiedDate)
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

    private static func uncategorizedOnBudgetActivity(through month: String, in database: isolated BudgetDatabase, db: Database) throws -> Int {
        guard try database.tableExists("transactions", db: db), try database.tableExists("accounts", db: db) else {
            return 0
        }

        let columns = try database.columnSet(for: "transactions", db: db)
        let split = TransactionSplitQueryExpressions(columns: columns)
        let budgetMonth = database.normalizedMonthExpression(split.qualifiedDate)
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

    static func fetchCategoryGroups(
        categoryValues: [String: BudgetCategoryValue],
        userNoteIDs: Set<String> = [],
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [BudgetMonthCategoryGroup] {
        guard try database.tableExists("category_groups", db: db) else {
            return []
        }

        let table = try database.budgetTable(db: db)
        let groupColumns = try database.columnSet(for: "category_groups", db: db)
        let groupHidden = database.column("hidden", fallback: "0", columns: groupColumns)
        let groupIncome = database.column("is_income", fallback: "0", columns: groupColumns)
        // Actual's category list: income groups last, then sort_order and id.
        let groupOrder = groupColumns.contains("sort_order")
            ? "\(groupIncome), sort_order, id"
            : "\(groupIncome), lower(name)"
        let groupRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, \(groupIncome) AS is_income, \(groupHidden) AS hidden
                FROM category_groups
                WHERE \(database.predicateForLiveRows(columns: groupColumns))
                ORDER BY \(groupOrder)
                """
        )

        let categoriesByGroup = try fetchBudgetCategoriesByGroup(
            categoryValues: categoryValues,
            userNoteIDs: userNoteIDs,
            in: database,
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
                isIncome: SQLiteValueCoercion.lenientBool(groupRow["is_income"]),
                hidden: SQLiteValueCoercion.lenientBool(groupRow["hidden"]),
                budgeted: try BudgetFinancialCalculation.sum(included.map(\.budgeted), table: table),
                spent: try BudgetFinancialCalculation.sum(included.map(\.spent), table: table),
                balance: try BudgetFinancialCalculation.sum(included.map(\.balance), table: table),
                categories: categories,
                hasUserNote: userNoteIDs.contains(groupID)
            ))
        }
        return result
    }

    private static func fetchBudgetCategoriesByGroup(
        categoryValues: [String: BudgetCategoryValue],
        userNoteIDs: Set<String> = [],
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [String: [BudgetMonthCategory]] {
        guard try database.tableExists("categories", db: db) else {
            return [:]
        }

        let categoryColumns = try database.columnSet(for: "categories", db: db)
        let groupColumn = database.column("cat_group", fallback: database.column("group_id", fallback: "NULL", columns: categoryColumns), columns: categoryColumns)
        let categoryHidden = database.column("hidden", fallback: "0", columns: categoryColumns)
        let categoryIncome = database.column("is_income", fallback: "0", columns: categoryColumns)
        let goalDefinition = database.column("goal_def", fallback: "NULL", columns: categoryColumns)
        let categoryOrder = categoryColumns.contains("sort_order") ? "sort_order, lower(name)" : "lower(name)"
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, \(categoryIncome) AS is_income, \(categoryHidden) AS hidden,
                       \(groupColumn) AS group_id, \(goalDefinition) AS goal_def
                FROM categories
                WHERE \(database.predicateForLiveRows(columns: categoryColumns))
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
                isIncome: SQLiteValueCoercion.lenientBool(row["is_income"]),
                hidden: SQLiteValueCoercion.lenientBool(row["hidden"]),
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

    static func hasStoredTemplateDefinition(_ rawValue: String?) -> Bool {
        switch BudgetTemplateDefinition.parseEntries(from: rawValue) {
        case .success(let definitions):
            return !definitions.isEmpty
        case .failure:
            // Keep malformed stored definitions visible so Apply Template can
            // surface the existing fail-closed validation error.
            return true
        }
    }

    struct EnvelopeCarryIn: Equatable {
        /// Upstream `from-last-month`: previous `to-budget` plus previous `buffered-selected`.
        let fromLastMonth: Int
        /// Upstream `last-month-overspent`: previous leftover below zero, summed over
        /// expense categories without carryover.
        let lastMonthOverspent: Int
    }

    /// Envelope month values from loot-core `budget/envelope.ts`, derived from the
    /// previous month's category values so a month read needs no second recurrence.
    /// Identity: `toBudget == totalIncome + fromLastMonth + lastMonthOverspent
    /// - totalBudgeted - forNextMonth`.
    static func envelopeCarryIn(
        month: String,
        groups: [BudgetMonthCategoryGroup],
        previousValues: [String: BudgetCategoryValue],
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> EnvelopeCarryIn {
        let previousMonth = YearMonth.id(packed: YearMonth.shiftedUnchecked(packed: YearMonth.packedUnchecked(month), by: -1))
        let expenseCategoryIDs = groups.filter { !$0.isIncome }.flatMap(\.categories).map(\.id)
        let previous = expenseCategoryIDs.map { previousValues[$0] ?? BudgetCategoryValue() }
        let previousAvailability = try envelopeAvailability(
            month: previousMonth,
            totalBalance: try BudgetFinancialCalculation.sum(previous.map(\.balance), table: .envelope),
            in: database,
            db: db
        )
        let overspent = try BudgetFinancialCalculation.sum(
            previous.filter { !$0.carryover }.map { min(0, $0.balance) },
            table: .envelope
        )
        return EnvelopeCarryIn(
            fromLastMonth: try BudgetTemplateEngine.checkedAdd(
                previousAvailability.toBudget,
                previousAvailability.holdForNextMonth
            ),
            lastMonthOverspent: overspent
        )
    }

    static func fetchAvailableMonths(in database: isolated BudgetDatabase) throws -> [String] {
        try database.queue.read { db in try fetchAvailableMonths(in: database, db: db) }
    }

    static func fetchAvailableMonths(in database: isolated BudgetDatabase, db: Database) throws -> [String] {
        var months = Set<String>()
        let table = try database.budgetTable(db: db).rawValue
        if try database.tableExists(table, db: db), try database.columnSet(for: table, db: db).contains("month") {
            let normalizedMonth = database.normalizedMonthExpression("month")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT \(normalizedMonth) AS month
                    FROM \(database.quotedIdentifier(table))
                    WHERE month IS NOT NULL
                    """
            )
            months.formUnion(rows.compactMap { YearMonth.canonicalID(SQLiteValueCoercion.lenientString($0["month"])) })
        }
        if try database.tableExists("transactions", db: db), try database.columnSet(for: "transactions", db: db).contains("date") {
            let columns = try database.columnSet(for: "transactions", db: db)
            // Envelope keeps deleted rows' months: upstream sizes the month range from the
            // earliest row of the raw `transactions` table (`createAllBudgets`, budget/base.ts),
            // tombstones included. Tracking filters them here, which upstream does not do.
            let live = table == BudgetTable.tracking.rawValue ? database.predicateForLiveRows(columns: columns) : "1 = 1"
            let normalizedMonth = database.normalizedMonthExpression("date")
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
