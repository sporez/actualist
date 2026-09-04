import Foundation

/// Display-unit amount and integer field parsing for the template editor.
///
/// Template JSON stores Actual display amounts, not minor units. Conversion
/// goes through `BudgetCurrency` so scale stays catalog-owned.
enum BudgetTemplateAmountInput {
    static func parseAmount(_ text: String, currency: BudgetCurrency) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let decimal = Decimal(string: trimmed),
              let minor = currency.minorUnits(fromDisplay: decimal) else {
            return nil
        }
        return currency.displayUnits(fromMinorUnits: minor)
    }

    static func formatAmount(_ amount: Double, currency: BudgetCurrency) -> String {
        let minor = currency.minorUnits(fromDisplay: amount) ?? 0
        return currency.editableAmountText(fromMinorUnits: minor)
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
