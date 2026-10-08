import Foundation

/// Shared display formatting for duplicate and merge reviews. These helpers
/// turn already-decided domain values into text; they do not choose amounts,
/// winners, or authorization.
enum TransactionCommandReviewFormatting {
    static func dateText(_ dayID: String, locale: Locale) -> String {
        ActualDateDisplay.mediumDay(dayID, locale: locale) ?? (dayID.isEmpty ? "Date unavailable" : dayID)
    }

    static func amountText(
        _ minorUnits: Int,
        seed: String,
        currency: BudgetCurrency,
        isPrivacyModeEnabled: Bool
    ) -> String {
        guard isPrivacyModeEnabled else { return currency.formatted(minorUnits) }
        return PrivacyDisplay.money(minorUnits, seed: seed, currency: currency)
    }

    static func role(isParent: Bool, isChild: Bool, isTransfer: Bool = false) -> String {
        if isChild { return "Split entry" }
        if isParent { return "Split transaction" }
        if isTransfer { return "Transfer" }
        return "Transaction"
    }

    /// Row title: the payee (or transfer counterpart account) when known,
    /// otherwise the generic role. Sample-values mode masks it like the feed.
    static func rowTitle(
        payeeName: String?,
        isTransfer: Bool,
        role: String,
        seed: String,
        isPrivacyModeEnabled: Bool
    ) -> String {
        guard let payeeName, !payeeName.isEmpty else { return role }
        guard isPrivacyModeEnabled else { return payeeName }
        return PrivacyDisplay.name(for: isTransfer ? .account : .payee, seed: seed)
    }

    static func note(_ value: String?, isPrivacyModeEnabled: Bool) -> String? {
        guard !isPrivacyModeEnabled,
              let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// Same sentence the batch review uses before a reconciled confirmation.
    static func reconciledConfirmationMessage(count: Int, locale: Locale) -> String {
        let countText = count.formatted(.number.locale(locale))
        return "\(countText) reconciled transaction\(count == 1 ? " is" : "s are") connected to these changes."
    }
}
