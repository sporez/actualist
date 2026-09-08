import Foundation

/// Planned savings remain stable when the displayed month becomes historical.
/// Templates consume plannedSavings; the headline chooses planned or actual.
struct TrackingBudgetSummary: Codable, Hashable, Sendable {
    let budgetedIncome: Int
    let budgetedExpenses: Int
    let receivedIncome: Int
    let expenseActivity: Int
    let plannedSavings: Int
    let actualSavings: Int

    enum Kind: String, Codable, Sendable {
        case projectedSavings
        case saved
        case overspent

        var title: String {
            switch self {
            case .projectedSavings: "Projected Savings"
            case .saved: "Saved"
            case .overspent: "Overspent"
            }
        }
    }

    struct Headline: Equatable, Sendable {
        let kind: Kind
        let amount: Int
        let income: Int
        let expenses: Int
    }

    func headline(month: String, currentMonth: String) -> Headline {
        if month >= currentMonth {
            return Headline(kind: .projectedSavings, amount: plannedSavings,
                income: budgetedIncome, expenses: budgetedExpenses)
        }
        return Headline(kind: actualSavings < 0 ? .overspent : .saved,
            amount: actualSavings, income: receivedIncome, expenses: -expenseActivity)
    }
}
