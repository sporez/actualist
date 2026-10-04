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

extension BudgetDatabase {
    func categoryValueInputs(db: Database) throws -> BudgetCategoryValueInputs {
        let table = try budgetTable(db: db)
        return BudgetCategoryValueInputs(
            table: table,
            incomeByCategory: table == .tracking ? try templateCategoryIsIncomeByID(db: db) : [:],
            budgetedByMonth: try categoryBudgetsByMonth(db: db),
            spentByMonth: try categorySpendingByMonth(db: db)
        )
    }

    /// Runs the recurrence once, forward, from the first month that holds real
    /// data (a non-zero budget or activity, or a carryover flag). Months before
    /// it only contribute zero values, so a stray 1900 row does not cost a loop
    /// over every month since. Snapshots are kept for `keepFrom...target`.
    func categoryValueTimeline(
        inputs: BudgetCategoryValueInputs,
        through targetMonthInt: Int,
        keepFrom: Int
    ) throws -> BudgetCategoryValueTimeline {
        var candidateMonths: Set<Int> = []
        for key in Set(inputs.budgetedByMonth.keys).union(inputs.spentByMonth.keys) {
            if let month = canonicalMonthID(key).map(monthInt), month <= targetMonthInt {
                candidateMonths.insert(month)
            }
        }
        func categoryIDs(in month: Int) -> Set<String> {
            let key = monthID(month)
            return Set((inputs.budgetedByMonth[key] ?? [:]).keys)
                .union((inputs.spentByMonth[key] ?? [:]).keys)
        }
        func hasRealData(in month: Int) -> Bool {
            let key = monthID(month)
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
            let key = monthID(monthCursor)
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
            monthCursor = nextMonth(after: monthCursor)
        }
        return BudgetCategoryValueTimeline(
            snapshots: snapshots,
            previous: previousValues,
            monthsComputed: monthsComputed
        )
    }
}
