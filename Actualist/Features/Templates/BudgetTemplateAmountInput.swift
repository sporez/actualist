import Foundation

/// Display-unit amount and integer field parsing for the template editor.
///
/// Template JSON stores Actual display amounts, not minor units. Money text goes
/// through `BudgetMoneyInputFormat`, so these fields read what the web app's do.
enum BudgetTemplateAmountInput {
    /// Typed text in display units, read the way Actual's amount fields read it.
    static func parseAmount(_ text: String, currency: BudgetCurrency) -> Double? {
        guard case .success(let minor) = BudgetMoneyInputFormat.minorUnits(text, currency: currency) else {
            return nil
        }
        return currency.displayUnits(fromMinorUnits: minor)
    }

    static func formatAmount(_ amount: Double, currency: BudgetCurrency) -> String {
        guard let minor = currency.minorUnits(fromDisplay: amount) else { return String(amount) }
        // Hide-fraction is a display preference. Editing must retain cents.
        return BudgetMoneyInputFormat.editText(minorUnits: minor, currency: currency)
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
        PrivacyDisplay.text(minorUnits, enabled: randomized, seed: seed, currency: currency, nilText: "—")
    }
}
