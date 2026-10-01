import Foundation

/// Display projection for a duplicate review. Family collapse is reported
/// here so the sheet does not decide when several selections become one copy.
struct TransactionDuplicateReviewDisplay: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let sourceTransactionID: String
        let role: String
        let context: String
        let amount: String
        let note: String?
    }

    struct Group: Equatable, Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    let title = "Review Duplicate Transactions"
    let confirmationTitle = "Duplicate"
    let subtitle: String
    let selectedCountText: String
    let copyCountText: String
    let familyDeduplicationMessage: String?
    let unavailableMessage: String?
    let groups: [Group]
    let canSubmit: Bool

    init(
        review: TransactionDuplicateReview,
        currency: BudgetCurrency,
        locale: Locale = .current,
        isPrivacyModeEnabled: Bool = false
    ) {
        let selectedCount = review.selections.count
        let copyCount = review.groups.reduce(0) { $0 + $1.rows.count }
        selectedCountText = selectedCount.formatted(.number.locale(locale))
        copyCountText = copyCount.formatted(.number.locale(locale))
        familyDeduplicationMessage = Self.familyMessage(for: review, locale: locale)
        canSubmit = review.canSubmit && !review.groups.isEmpty
        unavailableMessage = canSubmit
            ? nil
            : "These transactions cannot be duplicated."
        subtitle = familyDeduplicationMessage == nil
            ? "These are the copies that will be saved together."
            : "Selected rows that belong to the same transaction are copied once."
        groups = review.groups.enumerated().map { index, group in
            Group(
                id: group.id,
                title: review.groups.count == 1
                    ? "New copy"
                    : "New copy \(index + 1)",
                rows: group.rows.map { row in
                    Row(
                        id: row.duplicateTransactionID,
                        sourceTransactionID: row.sourceTransactionID,
                        role: TransactionCommandReviewFormatting.role(
                            isParent: row.isParent,
                            isChild: row.isChild,
                            isTransfer: row.transferDuplicateTransactionID != nil
                        ),
                        context: TransactionCommandReviewFormatting.dateText(row.date, locale: locale),
                        amount: TransactionCommandReviewFormatting.amountText(
                            row.amountMinorUnits,
                            seed: "duplicate-review-\(row.duplicateTransactionID)-\(row.amountMinorUnits)",
                            currency: currency,
                            isPrivacyModeEnabled: isPrivacyModeEnabled
                        ),
                        note: nil
                    )
                }
            )
        }
    }

    private static func familyMessage(
        for review: TransactionDuplicateReview,
        locale: Locale
    ) -> String? {
        let collapsed = review.groups.filter { $0.selectedTransactionIDs.count > 1 }
        guard !collapsed.isEmpty else { return nil }
        let selectedCount = collapsed.reduce(0) { $0 + $1.selectedTransactionIDs.count }
        let selectedText = selectedCount.formatted(.number.locale(locale))
        if collapsed.count == 1 {
            return "\(selectedText) selected transactions belong to one transaction, so Duplicate creates one copy."
        }
        let groupText = collapsed.count.formatted(.number.locale(locale))
        return "\(selectedText) selected transactions belong to \(groupText) transactions, so each of those transactions is duplicated once."
    }
}
