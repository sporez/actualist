import AppIntents
import Foundation

enum ShortcutMoney {
    static var currencyCode: String {
        Locale.current.currency?.identifier ?? "USD"
    }

    static func intentAmount(minorUnits: Int) -> IntentCurrencyAmount {
        IntentCurrencyAmount(
            amount: Decimal(minorUnits) / 100,
            currencyCode: currencyCode
        )
    }

    static func minorUnits(from decimal: Decimal) throws -> Int {
        guard decimal.isFinite else {
            throw ShortcutsError.amountInvalid
        }

        var value = decimal
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)

        var cents = rounded * 100
        var centsRounded = Decimal()
        NSDecimalRound(&centsRounded, &cents, 0, .plain)

        let number = NSDecimalNumber(decimal: centsRounded)
        let minorUnits = number.intValue
        guard NSDecimalNumber(value: minorUnits) == number else {
            throw ShortcutsError.amountInvalid
        }
        return minorUnits
    }

    static func minorUnits(from amount: IntentCurrencyAmount) throws -> Int {
        let code = amount.currencyCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !code.isEmpty, code.caseInsensitiveCompare(currencyCode) != .orderedSame {
            throw ShortcutsError.currencyMismatch
        }
        return try minorUnits(from: amount.amount)
    }

    static func spoken(_ amount: IntentCurrencyAmount?) -> String {
        guard let amount else {
            return Money(minorUnits: 0).formatted()
        }
        return Money(minorUnits: (try? minorUnits(from: amount)) ?? 0).formatted()
    }

    static func spoken(minorUnits: Int) -> String {
        Money(minorUnits: minorUnits).formatted()
    }
}
