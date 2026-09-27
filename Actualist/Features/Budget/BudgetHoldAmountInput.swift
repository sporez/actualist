import Foundation

/// Manual holds use a positive portion of unassigned money, never total income.
enum BudgetHoldAmountInput {
    static func amount(
        from text: String,
        available: Int,
        currency: BudgetCurrency,
        locale: Locale
    ) -> Int? {
        guard let decimal = try? BudgetMoneyInputFormat(currency: currency, locale: locale).parse(text),
              let amount = currency.minorUnits(fromDisplay: decimal),
              currency.displayAmount(fromMinorUnits: amount) == decimal,
              amount > 0, amount <= available,
              amount <= Money.maximumUserAmountMinorUnits else {
            return nil
        }
        return amount
    }

    static func text(amount: Int, currency: BudgetCurrency, locale: Locale) -> String {
        // Editable values retain every minor unit even when display cents are hidden.
        currency.displayAmount(fromMinorUnits: amount).formatted(
            .number.grouping(.never)
                .precision(.fractionLength(currency.decimalPlaces...currency.decimalPlaces))
                .locale(locale)
        )
    }
}
