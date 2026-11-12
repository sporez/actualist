import Foundation

/// Owner of editable money text. The static `minorUnits`, `autoDecimalsText` and
/// `editText` read and write amounts the way Actual's amount fields do, by the budget's
/// number format.
enum BudgetMoneyInputFormat {
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

    /// The text for a stored amount in an editable field, as Actual's `forEdit` writes it: every
    /// minor unit, the budget's thousands and decimal separators. `minorUnits` reads it back.
    static func editText(minorUnits: Int, currency: BudgetCurrency) -> String {
        decimalText(magnitudeDigits: String(minorUnits.magnitude), negative: minorUnits < 0, currency: currency)
    }

    private static func decimalText(magnitudeDigits: String, negative: Bool, currency: BudgetCurrency) -> String {
        let places = currency.decimalPlaces
        let trimmed = magnitudeDigits.drop { $0 == "0" }
        let padded = String(repeating: "0", count: max(0, places + 1 - trimmed.count)) + trimmed
        let sign = negative ? "-" : ""
        let format = currency.numberFormat
        guard places > 0 else { return sign + grouped(padded, format) }
        let split = padded.index(padded.endIndex, offsetBy: -places)
        return sign + grouped(String(padded[..<split]), format) + String(format.decimalSeparator) + padded[split...]
    }

    /// Thousands separators as Actual's `Intl.NumberFormat` places them: groups of three,
    /// or a first group of three then pairs for `comma-dot-in`.
    private static func grouped(_ integerDigits: String, _ format: ActualNumberFormat) -> String {
        var groups: [Substring] = []
        var rest = Substring(integerDigits)
        var size = 3
        while rest.count > size {
            groups.insert(rest.suffix(size), at: 0)
            rest = rest.dropLast(size)
            if format == .commaDotIn { size = 2 }
        }
        groups.insert(rest, at: 0)
        return groups.joined(separator: String(format.thousandsSeparator))
    }
}

enum MoneyInputError: Error, Hashable, Sendable {
    case empty
    case invalid
    case outOfRange
}
