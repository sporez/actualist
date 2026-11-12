import Foundation

/// Owner of editable money text. The static `minorUnits`, `autoDecimalsText` and
/// `editText` read and write amounts the way Actual's amount fields do, by the budget's
/// number format. The format-style value below is the device-locale `TextField`
/// binding that the rule value editor still uses.
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

    /// The device-locale reader the four inputs still use until they move to `minorUnits(_:currency:)`.
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

    /// A typed amount as integer minor units, the way Actual reads it: arithmetic such as
    /// `10+5`, then the budget's number format, then `Math.round(amount * 10^decimalPlaces)`
    /// with Double math, so `1.005` is 100. A blank field is `.empty`. Magnitudes above
    /// `Money.maximumUserAmountMinorUnits` (and non-finite results) are `.outOfRange`.
    static func minorUnits(_ text: String, currency: BudgetCurrency) -> Result<Int, MoneyInputError> {
        guard text.utf16.contains(where: { !ActualAmountText.isTrimmedAway($0) }) else {
            return .failure(.empty)
        }
        guard let amount = ActualAmountText.fromEdit(text, numberFormat: currency.numberFormat) else {
            return .failure(.invalid)
        }
        let rounded = ActualAmountText.javaScriptRound(amount * pow(10, Double(currency.decimalPlaces)))
        guard rounded.isFinite, abs(rounded) <= Double(Money.maximumUserAmountMinorUnits) else {
            return .failure(.outOfRange)
        }
        return .success(Int(rounded))
    }

    /// Actual's Hold field keeps only the typed digits and shifts them into the decimals
    /// (`1005` shows `10,05`), so a typed point or sign never reaches the parser.
    static func autoDecimalsText(_ typed: String, currency: BudgetCurrency) -> String {
        let digits = typed.unicodeScalars.filter { $0.value >= 0x30 && $0.value <= 0x39 }
        guard !digits.isEmpty else { return "" }
        return decimalText(
            magnitudeDigits: String(String.UnicodeScalarView(digits)),
            negative: false,
            currency: currency
        )
    }

    /// The text for a stored amount in an editable field: every minor unit, no thousands
    /// separators, and the budget's decimal separator, which `minorUnits` reads back.
    static func editText(minorUnits: Int, currency: BudgetCurrency) -> String {
        decimalText(magnitudeDigits: String(minorUnits.magnitude), negative: minorUnits < 0, currency: currency)
    }

    private static func decimalText(magnitudeDigits: String, negative: Bool, currency: BudgetCurrency) -> String {
        let places = currency.decimalPlaces
        let trimmed = magnitudeDigits.drop { $0 == "0" }
        let padded = String(repeating: "0", count: max(0, places + 1 - trimmed.count)) + trimmed
        let sign = negative ? "-" : ""
        guard places > 0 else { return sign + padded }
        let split = padded.index(padded.endIndex, offsetBy: -places)
        return sign + padded[..<split] + String(currency.numberFormat.decimalSeparator) + padded[split...]
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
    case empty
    case invalid
    case tooManyFractionDigits
    case outOfRange
}
