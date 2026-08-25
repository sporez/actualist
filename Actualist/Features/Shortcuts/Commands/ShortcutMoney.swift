import AppIntents
import Foundation

enum ShortcutMoney {
    static var fallback: BudgetCurrency {
        BudgetCurrency.catalog(code: Locale.current.currency?.identifier ?? "USD")
    }

    static var currencyCode: String {
        fallback.code
    }

    static func intentAmount(
        minorUnits: Int,
        currency: BudgetCurrency? = nil
    ) -> IntentCurrencyAmount {
        let resolved = currency ?? fallback
        return IntentCurrencyAmount(
            amount: resolved.displayAmount(fromMinorUnits: minorUnits),
            currencyCode: resolved.code
        )
    }

    static func minorUnits(
        from decimal: Decimal,
        currency: BudgetCurrency? = nil
    ) throws -> Int {
        let resolved = currency ?? fallback
        guard let value = resolved.minorUnits(fromDisplay: decimal) else {
            throw ShortcutsError.amountInvalid
        }
        return value
    }

    static func minorUnits(
        from amount: IntentCurrencyAmount,
        currency: BudgetCurrency? = nil
    ) throws -> Int {
        let resolved = currency ?? fallback
        let code = amount.currencyCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !code.isEmpty, code.caseInsensitiveCompare(resolved.code) != .orderedSame {
            throw ShortcutsError.currencyMismatch
        }
        return try minorUnits(from: amount.amount, currency: resolved)
    }

    static func spoken(
        _ amount: IntentCurrencyAmount?,
        currency: BudgetCurrency? = nil
    ) -> String {
        let resolved = currency ?? fallback
        guard let amount else {
            return resolved.formatted(0)
        }
        return resolved.formatted((try? minorUnits(from: amount, currency: resolved)) ?? 0)
    }

    static func spoken(minorUnits: Int, currency: BudgetCurrency? = nil) -> String {
        (currency ?? fallback).formatted(minorUnits)
    }
}
