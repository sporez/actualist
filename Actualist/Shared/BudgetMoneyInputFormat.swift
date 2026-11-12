import Foundation

/// Native currency formatting with full-string parsing for editable money
/// fields, so pasted suffixes cannot silently become a different saved amount.
struct BudgetMoneyInputFormat: ParseableFormatStyle, ParseStrategy {
    let currencyCode: String
    var locale: Locale

    init(currency: BudgetCurrency, locale: Locale) {
        currencyCode = currency.code
        self.locale = locale
    }

    var parseStrategy: Self { self }

    func format(_ value: Decimal) -> String {
        currencyCode.isEmpty ? number.format(value) : currency.format(value)
    }

    func parse(_ value: String) throws -> Decimal {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let amount: Decimal?
        if !currencyCode.isEmpty, let match = text.wholeMatch(of: currency) {
            amount = match.output
        } else {
            amount = text.wholeMatch(of: number)?.output
        }
        guard let amount, amount.isFinite else { throw CocoaError(.formatting) }
        return amount
    }

    /// Whole-field text to integer minor units. `.reject` refuses digits beyond
    /// the currency scale; `.round` rounds them half away from zero.
    static func minorUnits(
        _ text: String,
        currency: BudgetCurrency,
        locale: Locale,
        fractionPolicy: MoneyFractionPolicy
    ) -> Result<Int, MoneyInputError> {
        guard let decimal = try? Self(currency: currency, locale: locale).parse(text) else {
            return .failure(.invalid)
        }
        guard let amount = currency.minorUnits(fromDisplay: decimal) else {
            return .failure(.outOfRange)
        }
        if fractionPolicy == .reject, currency.displayAmount(fromMinorUnits: amount) != decimal {
            return .failure(.tooManyFractionDigits)
        }
        return .success(amount)
    }

    // A stable, unpadded style avoids inserting cents during typing or replacing
    // unfinished native text when focus changes. BudgetCurrency still owns rounding.
    private var number: Decimal.FormatStyle {
        .number.precision(.fractionLength(0...38)).locale(locale)
    }

    private var currency: Decimal.FormatStyle.Currency {
        .currency(code: currencyCode).precision(.fractionLength(0...38)).locale(locale)
    }
}

enum MoneyFractionPolicy: Sendable {
    case reject
    case round
}

enum MoneyInputError: Error, Hashable, Sendable {
    case invalid
    case tooManyFractionDigits
    case outOfRange
}
