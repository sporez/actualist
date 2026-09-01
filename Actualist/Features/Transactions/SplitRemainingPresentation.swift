import Foundation

/// Shared left/over copy for split remainder. `SplitTransactionError.difference`
/// is parent minus children; Actual web flips that for expense parents so a
/// negative remainder on a spend shows as left, not over.
enum SplitRemainingPresentation {
    static func displayedCents(remaining: Int, parentSignedAmount: Int) -> Int {
        parentSignedAmount > 0 ? remaining : -remaining
    }

    static func statusText(displayedCents: Int, currency: BudgetCurrency) -> String {
        if displayedCents == 0 {
            return "\(currency.formatted(0)) Remaining"
        }
        if displayedCents > 0 {
            return "\(currency.formatted(displayedCents)) left"
        }
        return "\(currency.formatted(abs(displayedCents))) over"
    }

    static func statusText(
        remaining: Int,
        parentSignedAmount: Int,
        currency: BudgetCurrency
    ) -> String {
        statusText(
            displayedCents: displayedCents(remaining: remaining, parentSignedAmount: parentSignedAmount),
            currency: currency
        )
    }
}
