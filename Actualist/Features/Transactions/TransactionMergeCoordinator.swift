import Foundation

/// Merge review and commit for the exact tap order. The selected-actions menu
/// offers Merge only at two rows; the coordinator still forwards the order it
/// was given so the backend can block any other count before confirmation.
enum TransactionMergeCommand: ReviewCommand {
    static func id(of review: TransactionMergeReview) -> String { review.id }
    static func fingerprint(of review: TransactionMergeReview) -> String { review.reviewFingerprint }
    static func context(of review: TransactionMergeReview) -> TransactionSelectionContext { review.context }

    /// Accepts a blocked review so the reason can appear before confirmation.
    static func echoes(_ review: TransactionMergeReview, selections: [TransactionSelectionIdentity]) -> Bool {
        let blockedAgrees = review.blockedReason == nil || !review.canSubmit
        return review.orderedTransactionIDs == selections.map(\.transactionID) && blockedAgrees
    }

    static func allowsSubmission(of review: TransactionMergeReview) -> Bool {
        review.canSubmit && review.blockedReason == nil
    }
}

typealias TransactionMergeCoordinator = ReviewCommandCoordinator<TransactionMergeCommand>

extension ReviewCommandCoordinator where Command == TransactionMergeCommand {
    /// The authorization object the merge commit compares exactly. Empty
    /// reconciled IDs stay unauthorized; a non-empty list is passed through
    /// unchanged, including order.
    nonisolated static func authorization(for review: TransactionMergeReview) -> TransactionMergeAuthorization? {
        guard !review.reconciledTransactionIDs.isEmpty else { return nil }
        return TransactionMergeAuthorization(
            reviewID: review.id,
            reviewFingerprint: review.reviewFingerprint,
            reconciledTransactionIDs: review.reconciledTransactionIDs
        )
    }
}
