import Foundation

/// The category recurrence and aggregate contract shared by reads and templates.
/// SQL owns activity selection; this value never re-sums transactions.
enum BudgetFinancialCalculation {
    static func category(
        table: BudgetTable,
        isIncome: Bool,
        budgeted: Int,
        activity: Int,
        carryover: Bool,
        previous: BudgetCategoryValue
    ) throws -> BudgetCategoryValue {
        let contribution = previous.carryover ? previous.balance
            : (table == .tracking ? 0 : max(0, previous.balance))
        let signedActivity: Int
        if table == .tracking && isIncome {
            guard activity != Int.min else { throw LocalFirstError.numericValueOutOfRange }
            signedActivity = -activity
        } else {
            signedActivity = activity
        }
        return BudgetCategoryValue(budgeted: budgeted, spent: activity,
            balance: try sum([budgeted, signedActivity, contribution], table: table), carryover: carryover)
    }

    static func includedCategories(
        _ categories: [BudgetMonthCategory], table: BudgetTable
    ) -> [BudgetMonthCategory] {
        table == .tracking ? categories.filter { $0.hidden != true } : categories
    }

    struct Totals {
        let budgeted: Int
        let spent: Int
        let balance: Int
        let income: Int
        let tracking: TrackingBudgetSummary?
    }

    static func totals(groups: [BudgetMonthCategoryGroup], table: BudgetTable) throws -> Totals {
        let expenses = groups.filter { !$0.isIncome && (table == .envelope || $0.hidden != true) }
        let incomeGroups = groups.filter(\.isIncome)
        let budgeted = try sum(expenses.map(\.budgeted), table: table)
        let spent = try sum(expenses.map(\.spent), table: table)
        let balance = try sum(expenses.map(\.balance), table: table)
        let income = table == .tracking ? incomeGroups.first?.spent ?? 0
            : try sum(incomeGroups.map(\.spent), table: table)
        let summary: TrackingBudgetSummary?
        if table == .tracking {
            let plannedIncome = incomeGroups.first?.budgeted ?? 0
            summary = TrackingBudgetSummary(budgetedIncome: plannedIncome,
                budgetedExpenses: budgeted, receivedIncome: income, expenseActivity: spent,
                plannedSavings: try sum([plannedIncome, -budgeted], table: table),
                actualSavings: try sum([income, spent], table: table))
        } else {
            summary = nil
        }
        return Totals(budgeted: budgeted, spent: spent, balance: balance, income: income, tracking: summary)
    }

    /// Tracking sheet arithmetic uses Actual's safeNumber bound (2^51 - 1),
    /// which is stricter than Swift overflow and the existing input digit limit.
    static func sum(_ amounts: [Int], table: BudgetTable) throws -> Int {
        var total = 0
        for amount in amounts {
            let addition = total.addingReportingOverflow(amount)
            guard !addition.overflow else { throw LocalFirstError.numericValueOutOfRange }
            total = addition.partialValue
        }
        if table == .tracking {
            let limit = (1 << 51) - 1
            guard (-limit...limit).contains(total) else { throw LocalFirstError.numericValueOutOfRange }
        }
        return total
    }
}
