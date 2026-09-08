import Foundation

/// Display semantics only; repository/database eligibility still guards writes.
struct BudgetModePresentation: Hashable {
    var isTracking = false
    var isIncome = false

    var budgetedLabel: String { isTracking ? "Budgeted" : "Assigned" }
    var activityLabel: String { isIncome ? "Received" : "Spent" }
    var balanceLabel: String { isTracking ? "Balance" : "Available" }
    var showsActivity: Bool { isTracking }
    var showsBalance: Bool { !isTracking || !isIncome }
    var rolloverTitle: String { isTracking ? "Rollover Balance" : "Rollover Overspending" }
    var rolloverExplanation: String {
        isTracking ? "Carry this category’s balance into the next month."
            : "Carry this category’s negative balance into following months."
    }
    func activityAmount(_ signedActivity: Int) -> Int { isIncome ? signedActivity : -signedActivity }
}

struct BudgetSavingsPresentation: Equatable {
    let title: String
    let amount: Int
    let amountText: String
    let incomeText: String
    let expensesText: String

    init?(month: BudgetMonth?, currency: BudgetCurrency, currentMonth: String = WidgetMonthID.current()) {
        guard let month, let summary = month.trackingSummary else { return nil }
        let headline = summary.headline(month: month.month, currentMonth: currentMonth)
        title = headline.kind.title
        amount = headline.amount
        amountText = currency.formatted(headline.amount)
        incomeText = "Income \(currency.formatted(headline.income))"
        expensesText = "Expenses \(currency.formatted(headline.expenses))"
    }
}
