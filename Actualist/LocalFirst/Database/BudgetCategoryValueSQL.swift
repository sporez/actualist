import Foundation
import GRDB

/// Everything Actual's per-category month recurrence reads from the file.
struct BudgetCategoryValueInputs {
    let table: BudgetTable
    let incomeByCategory: [String: Bool]
    let budgetedByMonth: [String: [String: (budgeted: Int, carryover: Bool)]]
    let spentByMonth: [String: [String: Int]]
}

/// Category values for the months a caller asked to keep. `previous` is the
/// month before the target (the zero-valued categories of earlier empty months
/// when the target is the first month with real data).
struct BudgetCategoryValueTimeline {
    var snapshots: [Int: [String: BudgetCategoryValue]]
    var previous: [String: BudgetCategoryValue]
    /// Months the recurrence ran; the work-count seam for tests.
    var monthsComputed = 0
}

enum BudgetCategoryValueSQL {
    /// With a `history`, reads and recurrence are shared with the rest of one
    /// template plan.
    static func categoryValues(
        through month: String,
        history: TemplateHistory? = nil,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [String: BudgetCategoryValue] {
        guard let history else {
            return try categoryValuesWithPrevious(through: month, in: database, db: db).current
        }
        guard YearMonth.canonicalID(month) == month else {
            throw LocalFirstError.invalidLocalWrite("invalid budget month")
        }
        let target = YearMonth.packedUnchecked(month)
        return try TemplateInputSQL.templateHistoryCategoryValues(history, at: target, keepFrom: target, in: database, db: db)
    }

    /// `previous` is the month before `month` (empty when `month` is the first
    /// month with data), captured while the same recurrence runs.
    static func categoryValuesWithPrevious(
        through month: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> (current: [String: BudgetCategoryValue], previous: [String: BudgetCategoryValue]) {
        guard YearMonth.canonicalID(month) == month else {
            throw LocalFirstError.invalidLocalWrite("invalid budget month")
        }
        let target = YearMonth.packedUnchecked(month)
        let timeline = try categoryValueTimeline(
            inputs: try categoryValueInputs(in: database, db: db),
            through: target,
            keepFrom: target
        )
        return (timeline.snapshots[target] ?? [:], timeline.previous)
    }

    static func categoryBudgetSource(in database: isolated BudgetDatabase, db: Database) throws -> (table: BudgetTable, columns: Set<String>)? {
        let table = try database.budgetTable(db: db)
        guard try database.tableExists(table.rawValue, db: db) else {
            return nil
        }
        return (table, try database.columnSet(for: table.rawValue, db: db))
    }

    static func categoryBudgets(month: String, in database: isolated BudgetDatabase, db: Database) throws -> [String: (budgeted: Int, carryover: Bool)] {
        guard let source = try categoryBudgetSource(in: database, db: db) else {
            return [:]
        }
        let category = database.column("category", fallback: "NULL", columns: source.columns)
        let amount = database.column("amount", fallback: "0", columns: source.columns)
        let carryover = database.column("carryover", fallback: "0", columns: source.columns)
        let budgetMonth = database.normalizedMonthExpression("month")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(category) AS category_id, \(amount) AS amount, \(carryover) AS carryover
                FROM \(database.quotedIdentifier(source.table.rawValue))
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
                    carryover: SQLiteValueCoercion.lenientBool(row["carryover"])
                )
            )
        })
    }

    private static func categoryBudgetsByMonth(in database: isolated BudgetDatabase, db: Database) throws -> [String: [String: (budgeted: Int, carryover: Bool)]] {
        guard let source = try categoryBudgetSource(in: database, db: db) else {
            return [:]
        }
        let category = database.column("category", fallback: "NULL", columns: source.columns)
        let amount = database.column("amount", fallback: "0", columns: source.columns)
        let carryover = database.column("carryover", fallback: "0", columns: source.columns)
        let budgetMonth = database.normalizedMonthExpression("month")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(budgetMonth) AS month, \(category) AS category_id, \(amount) AS amount, \(carryover) AS carryover
                FROM \(database.quotedIdentifier(source.table.rawValue))
                WHERE month IS NOT NULL
                """
        )
        return rows.reduce(into: [:]) { result, row in
            guard
                let month = SQLiteValueCoercion.lenientString(row["month"]),
                let categoryID = row["category_id"] as String?
            else {
                return
            }
            result[month, default: [:]][categoryID] = (
                budgeted: row["amount"] ?? 0,
                carryover: SQLiteValueCoercion.lenientBool(row["carryover"])
            )
        }
    }

    static func categorySpending(month: String, in database: isolated BudgetDatabase, db: Database) throws -> [String: Int] {
        guard try database.tableExists("transactions", db: db), try database.tableExists("accounts", db: db) else {
            return [:]
        }
        let columns = try database.columnSet(for: "transactions", db: db)
        let split = TransactionSplitQueryExpressions(columns: columns)
        let transferColumn = try database.categoryMappingTransferColumn(db: db)
        let categoryMappingJoin = transferColumn == nil
            ? ""
            : "LEFT JOIN category_mapping cm ON cm.id = \(split.qualifiedCategory)"
        let mappedCategory = transferColumn.map {
            "COALESCE(cm.\(database.quotedIdentifier($0)), \(split.qualifiedCategory))"
        } ?? split.qualifiedCategory
        let budgetMonth = database.normalizedMonthExpression(split.qualifiedDate)
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

    private static func categorySpendingByMonth(in database: isolated BudgetDatabase, db: Database) throws -> [String: [String: Int]] {
        guard try database.tableExists("transactions", db: db), try database.tableExists("accounts", db: db) else {
            return [:]
        }
        let columns = try database.columnSet(for: "transactions", db: db)
        let split = TransactionSplitQueryExpressions(columns: columns)
        let transferColumn = try database.categoryMappingTransferColumn(db: db)
        let categoryMappingJoin = transferColumn == nil
            ? ""
            : "LEFT JOIN category_mapping cm ON cm.id = \(split.qualifiedCategory)"
        let mappedCategory = transferColumn.map {
            "COALESCE(cm.\(database.quotedIdentifier($0)), \(split.qualifiedCategory))"
        } ?? split.qualifiedCategory
        let budgetMonth = database.normalizedMonthExpression(split.qualifiedDate)
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
                let month = SQLiteValueCoercion.lenientString(row["month"]),
                let categoryID = row["category_id"] as String?
            else {
                return
            }
            result[month, default: [:]][categoryID] = row["amount"] ?? 0
        }
    }

    static func categoryValueInputs(in database: isolated BudgetDatabase, db: Database) throws -> BudgetCategoryValueInputs {
        let table = try database.budgetTable(db: db)
        return BudgetCategoryValueInputs(
            table: table,
            incomeByCategory: table == .tracking ? try TemplateCategorySQL.templateCategoryIsIncomeByID(in: database, db: db) : [:],
            budgetedByMonth: try categoryBudgetsByMonth(in: database, db: db),
            spentByMonth: try categorySpendingByMonth(in: database, db: db)
        )
    }

    /// Runs the recurrence once, forward, from the first month that holds real
    /// data (a non-zero budget or activity, or a carryover flag). Months before
    /// it only contribute zero values, so a stray 1900 row does not cost a loop
    /// over every month since. Snapshots are kept for `keepFrom...target`.
    static func categoryValueTimeline(
        inputs: BudgetCategoryValueInputs,
        through targetMonthInt: Int,
        keepFrom: Int
    ) throws -> BudgetCategoryValueTimeline {
        var candidateMonths: Set<Int> = []
        for key in Set(inputs.budgetedByMonth.keys).union(inputs.spentByMonth.keys) {
            if let month = YearMonth.canonicalID(key).map(YearMonth.packedUnchecked), month <= targetMonthInt {
                candidateMonths.insert(month)
            }
        }
        func categoryIDs(in month: Int) -> Set<String> {
            let key = YearMonth.id(packed: month)
            return Set((inputs.budgetedByMonth[key] ?? [:]).keys)
                .union((inputs.spentByMonth[key] ?? [:]).keys)
        }
        func hasRealData(in month: Int) -> Bool {
            let key = YearMonth.id(packed: month)
            let budgeted = inputs.budgetedByMonth[key] ?? [:]
            let spent = inputs.spentByMonth[key] ?? [:]
            return budgeted.values.contains { $0.budgeted != 0 || $0.carryover }
                || spent.values.contains { $0 != 0 }
        }
        let start = candidateMonths.filter(hasRealData).min() ?? targetMonthInt

        var valuesByCategory: [String: BudgetCategoryValue] = [:]
        for month in candidateMonths where month < start {
            for categoryID in categoryIDs(in: month) {
                valuesByCategory[categoryID] = BudgetCategoryValue()
            }
        }
        var previousValues = valuesByCategory
        var snapshots: [Int: [String: BudgetCategoryValue]] = [:]

        var monthsComputed = 0
        var monthCursor = start
        while monthCursor <= targetMonthInt {
            let key = YearMonth.id(packed: monthCursor)
            let budgeted = inputs.budgetedByMonth[key] ?? [:]
            let spent = inputs.spentByMonth[key] ?? [:]
            var nextValues: [String: BudgetCategoryValue] = [:]
            for categoryID in Set(budgeted.keys).union(spent.keys).union(valuesByCategory.keys) {
                let budget = budgeted[categoryID] ?? (budgeted: 0, carryover: false)
                nextValues[categoryID] = try BudgetFinancialCalculation.category(
                    table: inputs.table,
                    isIncome: inputs.incomeByCategory[categoryID] ?? false,
                    budgeted: budget.budgeted,
                    activity: spent[categoryID] ?? 0,
                    carryover: budget.carryover,
                    previous: valuesByCategory[categoryID] ?? BudgetCategoryValue()
                )
            }
            previousValues = valuesByCategory
            valuesByCategory = nextValues
            if monthCursor >= keepFrom {
                snapshots[monthCursor] = nextValues
            }
            monthsComputed += 1
            monthCursor = YearMonth.nextUnchecked(packed: monthCursor)
        }
        return BudgetCategoryValueTimeline(
            snapshots: snapshots,
            previous: previousValues,
            monthsComputed: monthsComputed
        )
    }

    static func templateFromLastMonth(
        categoryID: String,
        monthValue: Int,
        isIncome: Bool,
        isTrackingBudget: Bool = false,
        history: TemplateHistory? = nil,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> Int {
        let previousMonthValue = try BudgetTemplateEngine().sourceMonthValue(
            for: monthValue,
            lookBack: 1
        )
        let previousMonth = YearMonth.id(packed: previousMonthValue)
        let previousValues = try categoryValues(through: previousMonth, history: history, in: database, db: db)[categoryID]
            ?? BudgetCategoryValue()
        // Actual: leftover < 0 && !carryover || is_income || tracking && !carryover
        if isIncome {
            return 0
        }
        if isTrackingBudget, !previousValues.carryover {
            return 0
        }
        if previousValues.balance < 0, !previousValues.carryover {
            return 0
        }
        return previousValues.balance
    }
}
