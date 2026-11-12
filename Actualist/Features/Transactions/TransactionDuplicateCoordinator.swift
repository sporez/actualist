import Foundation

/// Duplicate review and commit for every selected row, in tap order.
/// Selection itself stays on `TransactionSelectionCoordinator`; the command
/// copies that order and rejects a review that does not echo it.
enum TransactionDuplicateCommand: ReviewCommand {
    static func id(of review: TransactionDuplicateReview) -> String { review.id }
    static func fingerprint(of review: TransactionDuplicateReview) -> String { review.reviewFingerprint }
    static func context(of review: TransactionDuplicateReview) -> TransactionSelectionContext { review.context }

    /// Accepts only a review whose selections are the exact prepared order.
    /// A submittable review must also account for every selection in its groups.
    /// A non-submittable review is still accepted so the sheet can explain why
    /// before confirmation. A reordered echo is not accepted.
    static func echoes(_ review: TransactionDuplicateReview, selections: [TransactionSelectionIdentity]) -> Bool {
        let groupedIDs = review.groups.flatMap(\.selectedTransactionIDs)
        let preparedIDs = selections.map(\.transactionID)
        let groupsAccountForSelections = Set(groupedIDs).count == groupedIDs.count
            && Set(groupedIDs) == Set(preparedIDs)
        return review.selections == selections
            && (review.canSubmit ? groupsAccountForSelections && !review.groups.isEmpty : true)
    }

    static func allowsSubmission(of review: TransactionDuplicateReview) -> Bool { review.canSubmit }
}

typealias TransactionDuplicateCoordinator = ReviewCommandCoordinator<TransactionDuplicateCommand>
