import Foundation

/// Manual holds use a positive portion of unassigned money, never total income.
/// Typing follows Actual's Hold field: digits shift into the decimals, and an
/// amount above what is left to budget is held at that limit.
enum BudgetHoldAmountInput {
    /// What the field shows after a keystroke. Hide-fraction budgets type whole
    /// amounts as written, like Actual's `autoDecimals` switch.
    static func fieldText(typed: String, currency: BudgetCurrency) -> String {
        currency.hideFraction ? typed : BudgetMoneyInputFormat.autoDecimalsText(typed, currency: currency)
    }

    /// The amount to hold: more than zero, and no more than `available`.
    static func amount(from text: String, available: Int, currency: BudgetCurrency) -> Int? {
        guard available > 0,
              case .success(let typed) = BudgetMoneyInputFormat.minorUnits(text, currency: currency),
              typed > 0 else {
            return nil
        }
        return min(typed, available)
    }

    static func text(amount: Int, currency: BudgetCurrency) -> String {
        BudgetMoneyInputFormat.editText(minorUnits: amount, currency: currency)
    }

    /// Whether the typed amount is more than `available`, so the hold is limited to it.
    static func exceedsAvailable(text: String, available: Int, currency: BudgetCurrency) -> Bool {
        guard case .success(let typed) = BudgetMoneyInputFormat.minorUnits(text, currency: currency) else {
            return false
        }
        return typed > available
    }
}
