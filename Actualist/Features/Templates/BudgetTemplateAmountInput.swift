import Foundation

/// Display-unit amount and integer field parsing for the template editor.
///
/// Template JSON stores Actual display amounts, not minor units. Conversion
/// goes through `BudgetCurrency` so scale stays catalog-owned.
enum BudgetTemplateAmountInput {
    static func parseAmount(_ text: String, currency: BudgetCurrency) -> Double? {
        guard let decimal = numericValue(text),
              let minor = currency.minorUnits(fromDisplay: decimal) else {
            return nil
        }
        return currency.displayUnits(fromMinorUnits: minor)
    }

    static func formatAmount(_ amount: Double, currency: BudgetCurrency) -> String {
        guard let minor = currency.minorUnits(fromDisplay: amount) else { return String(amount) }
        // Hide-fraction is a display preference. Editing must retain cents.
        var editingCurrency = currency
        editingCurrency.hideFraction = false
        return editingCurrency.editableAmountText(fromMinorUnits: minor)
    }

    static func numericValue(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func inputText(_ value: Decimal?) -> String {
        value.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
    }

    static func parseInt(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int(trimmed) else {
            return nil
        }
        return value
    }

    static func parseWeight(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let value = Double(trimmed),
              value.isFinite else {
            return nil
        }
        return value
    }

    static func parsePercentage(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let value = Double(trimmed),
              value.isFinite else {
            return nil
        }
        return value
    }

    static func contributionText(
        minorUnits: Int?,
        currency: BudgetCurrency,
        randomized: Bool,
        seed: String
    ) -> String {
        guard let minorUnits else {
            return "—"
        }
        if randomized {
            return PrivacyDisplay.money(minorUnits, seed: seed, currency: currency)
        }
        return currency.formatted(minorUnits)
    }
}
