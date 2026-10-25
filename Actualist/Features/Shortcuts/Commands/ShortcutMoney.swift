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
        if !code.isEmpty, !resolved.accepts(code) {
            throw ShortcutsError.currencyMismatch
        }
        return try minorUnits(from: amount.amount, currency: resolved)
    }

    /// Siri on iOS 27.1 passes a required amount it never asked for as 0 (or
    /// a non-finite value) instead of prompting. Such an amount must be asked
    /// for, not rejected. Where 0 is a real value (a category budget), only a
    /// non-finite amount counts as missing.
    static func isMissing(_ amount: IntentCurrencyAmount, zeroIsMissing: Bool) -> Bool {
        !amount.amount.isFinite || (zeroIsMissing && amount.amount.isZero)
    }

    static func spoken(
        _ amount: IntentCurrencyAmount?,
        currency: BudgetCurrency? = nil
    ) -> String {
        let resolved = currency ?? amount.map { BudgetCurrency.catalog(code: $0.currencyCode) } ?? fallback
        guard let amount else {
            return resolved.formatted(0)
        }
        return resolved.formatted((try? minorUnits(from: amount, currency: resolved)) ?? 0)
    }

    static func spoken(minorUnits: Int, currency: BudgetCurrency? = nil) -> String {
        (currency ?? fallback).formatted(minorUnits)
    }
}
