import Foundation

/// Display semantics only; repository/database eligibility still guards writes.
struct BudgetModePresentation: Hashable {
    var isTracking = false
    var isIncome = false

    var budgetedLabel: String { isTracking ? "Budgeted" : "Assigned" }
    var activityLabel: String { isIncome ? "Received" : "Spent" }
    var balanceLabel: String { isTracking ? "Balance" : "Available" }
    var showsBalance: Bool { !isTracking || !isIncome }
    var secondValueLabel: String { isTracking && isIncome ? activityLabel : balanceLabel }

    func secondValue(balance: Int, activity: Int, carryover: Bool = false, currency: BudgetCurrency) -> BudgetSecondValuePresentation {
        BudgetSecondValuePresentation(
            amount: isTracking && isIncome ? activity : balance,
            label: secondValueLabel,
            carryover: !isIncome && carryover,
            currency: currency
        )
    }

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

struct BudgetSecondValuePresentation: Equatable {
    enum Tone { case negative, zero, positive }
    let text: String
    let label: String
    let tone: Tone
    let carryover: Bool
    var accessibilityText: String { "\(label), \(text)" + (carryover ? ", rollover enabled" : "") }

    init(amount: Int, label: String, carryover: Bool, currency: BudgetCurrency) {
        text = currency.formatted(amount)
        self.label = label
        tone = amount < 0 ? .negative : amount == 0 ? .zero : .positive
        self.carryover = carryover
    }
}
