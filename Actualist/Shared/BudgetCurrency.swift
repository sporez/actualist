import Foundation
import SwiftUI

/// The open budget's currency: ISO code, minor-unit scale, and hide-fraction.
///
/// Actual stores integer minor units and converts with
/// `round(amount * 10^decimalPlaces)`. This value is the only scale the
/// display / parse / template / intent boundaries should use.
struct BudgetCurrency: Hashable, Sendable {
    var code: String
    var decimalPlaces: Int
    var hideFraction: Bool

    static let none = BudgetCurrency(code: "", decimalPlaces: 2, hideFraction: false)
    static let usd = BudgetCurrency(code: "USD", decimalPlaces: 2, hideFraction: false)
    static let jpy = BudgetCurrency(code: "JPY", decimalPlaces: 0, hideFraction: false)
    static let krw = BudgetCurrency(code: "KRW", decimalPlaces: 0, hideFraction: false)

    /// Actual's bundled catalog uses the empty code for currency-neutral display.
    /// Known zero-decimal currencies use a scale of 1; unknown non-empty codes
    /// keep their ISO identifier and default to 2 decimal places.
    static func catalog(code: String, hideFraction: Bool = false) -> BudgetCurrency {
        let resolved = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let places = zeroDecimalCodes.contains(resolved) ? 0 : 2
        return BudgetCurrency(code: resolved, decimalPlaces: places, hideFraction: hideFraction)
    }

    var scale: Decimal {
        pow(Decimal(10), decimalPlaces)
    }

    /// Display units → integer minor units. `nil` for non-finite or unrepresentable values.
    func minorUnits(fromDisplay amount: Decimal) -> Int? {
        guard amount.isFinite else {
            return nil
        }

        var scaled = amount * scale
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let number = NSDecimalNumber(decimal: rounded)
        let value = number.intValue
        guard NSDecimalNumber(value: value) == number else {
            return nil
        }
        return value
    }

    func minorUnits(fromDisplay amount: Double) -> Int? {
        guard amount.isFinite else {
            return nil
        }
        return minorUnits(fromDisplay: Decimal(amount))
    }

    func displayAmount(fromMinorUnits value: Int) -> Decimal {
        Decimal(value) / scale
    }

    func displayUnits(fromMinorUnits value: Int) -> Double {
        NSDecimalNumber(decimal: displayAmount(fromMinorUnits: value)).doubleValue
    }

    var displayedFractionDigits: Int {
        hideFraction ? 0 : decimalPlaces
    }

    func formatted(_ minorUnits: Int) -> String {
        Money(minorUnits: minorUnits).formatted(using: self)
    }

    func editableAmountText(fromMinorUnits value: Int) -> String {
        let style = Decimal.FormatStyle
            .number
            .precision(.fractionLength(displayedFractionDigits...displayedFractionDigits))
            .locale(Locale(identifier: "en_US_POSIX"))
        return displayAmount(fromMinorUnits: value).formatted(style)
    }

    /// Whole-currency rounding used by template `removeFraction`.
    /// USD `12345` → `12300`; zero-decimal currencies are unchanged.
    func removingFraction(fromMinorUnits value: Int) -> Int {
        guard decimalPlaces > 0 else {
            return value
        }
        return minorUnits(fromDisplay: displayAmount(fromMinorUnits: value).rounded(to: 0)) ?? value
    }
}

extension Money {
    func decimalValue(using currency: BudgetCurrency) -> Decimal {
        currency.displayAmount(fromMinorUnits: minorUnits)
    }

    func formatted(using currency: BudgetCurrency) -> String {
        let amount = decimalValue(using: currency)
        if currency.code.isEmpty {
            return amount.formatted(currency.numberDisplayFormat)
        }
        return amount.formatted(currency.currencyDisplayFormat)
    }
}

private extension BudgetCurrency {
    static let zeroDecimalCodes: Set<String> = ["JPY", "KRW"]

    var numberDisplayFormat: Decimal.FormatStyle {
        .number.precision(.fractionLength(displayedFractionDigits...displayedFractionDigits))
    }

    var currencyDisplayFormat: Decimal.FormatStyle.Currency {
        .init(code: code).precision(.fractionLength(displayedFractionDigits...displayedFractionDigits))
    }
}

private extension Decimal {
    func rounded(to scale: Int) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .plain)
        return result
    }
}

private enum BudgetCurrencyEnvironmentKey: EnvironmentKey {
    static let defaultValue = BudgetCurrency.usd
}

extension EnvironmentValues {
    var budgetCurrency: BudgetCurrency {
        get { self[BudgetCurrencyEnvironmentKey.self] }
        set { self[BudgetCurrencyEnvironmentKey.self] = newValue }
    }
}
