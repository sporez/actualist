import Foundation

/// Display semantics only; repository/database eligibility still guards writes.
struct BudgetModePresentation: Hashable {
    var isTracking = false
    var isIncome = false

    var budgetedLabel: String { "Budgeted" }
    var activityLabel: String { isIncome ? "Received" : "Spent" }
    var balanceLabel: String { isTracking ? "Balance" : "Available" }
    var showsBalance: Bool { !isTracking || !isIncome }
    var secondValueLabel: String { isTracking && isIncome ? activityLabel : balanceLabel }

    /// Whether a row's values mean something other than its column heading says.
    func needsOwnLabels(under column: BudgetModePresentation) -> Bool {
        budgetedLabel != column.budgetedLabel || secondValueLabel != column.secondValueLabel
    }

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
        isTracking ? "Roll this category’s balance over into the next month."
            : "Roll this category’s negative balance over into the next month."
    }
    /// Category menu item, flipping like Hide/Show. The subtitle says what the
    /// tap leads to, so the title stays short enough not to wrap. Nil for income.
    func rolloverMenuLabel(isEnabled: Bool) -> BudgetRolloverMenuLabel? {
        guard !isIncome else { return nil }
        let subtitle = switch (isTracking, isEnabled) {
        case (false, false): "Overspending carries into next month"
        case (false, true): "Overspending comes out of next month’s To Budget"
        case (true, false): "The balance carries into next month"
        case (true, true): "The balance resets each month"
        }
        return BudgetRolloverMenuLabel(title: isEnabled ? "Stop Rolling Over" : "Roll Over", subtitle: subtitle)
    }
    func activityAmount(_ signedActivity: Int) -> Int { isIncome ? signedActivity : -signedActivity }
}

struct BudgetRolloverMenuLabel: Equatable {
    /// Matches the arrow badge on rows with rollover on.
    static let systemImage = "arrow.right"
    let title: String
    let subtitle: String
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
