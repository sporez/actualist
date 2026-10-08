import Foundation
import Observation

/// Merge review and commit for the exact tap order. The selected-actions menu
/// offers Merge only at two rows; this coordinator still forwards the order it
/// was given so the backend can block any other count before confirmation.
@MainActor
@Observable
final class TransactionMergeCoordinator {
    struct Preparation: Hashable, Sendable, Identifiable {
        let id: UUID
        let generation: UInt64
        let context: TransactionSelectionContext
        let selections: [TransactionSelectionIdentity]

        var orderedTransactionIDs: [String] { selections.map(\.transactionID) }
    }

    struct ReviewedMerge: Equatable {
        let selections: [TransactionSelectionIdentity]
        let review: TransactionMergeReview
    }

    enum State: Equatable {
        case idle
        case preparing(Preparation)
        case reviewing(ReviewedMerge)
        case submitting(ReviewedMerge)
        case failed(
            context: TransactionSelectionContext,
            message: String
        )
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var generation: UInt64 = 0

    var isSubmitting: Bool {
        if case .submitting = state { return true }
        return false
    }

    var hidesSelectionChrome: Bool {
        switch state {
        case .preparing, .reviewing, .submitting: true
        case .idle, .failed: false
        }
    }

    var failureMessage: String? {
        if case .failed(_, let message) = state { return message }
        return nil
    }

    var review: TransactionMergeReview? {
        switch state {
        case .reviewing(let reviewed), .submitting(let reviewed): reviewed.review
        case .idle, .preparing, .failed: nil
        }
    }

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

    @discardableResult
    func beginPreparation(
        context: TransactionSelectionContext,
        selections: [TransactionSelectionIdentity]
    ) -> Preparation? {
        switch state {
        case .idle, .failed:
            break
        case .preparing, .reviewing, .submitting:
            return nil
        }
        guard !selections.isEmpty else { return nil }
        generation &+= 1
        let preparation = Preparation(
            id: UUID(),
            generation: generation,
            context: context,
            selections: selections
        )
        state = .preparing(preparation)
        return preparation
    }

    func isCurrent(_ preparation: Preparation) -> Bool {
        guard case .preparing(let current) = state else { return false }
        return current == preparation && generation == preparation.generation
    }

    /// Accepts a blocked review so the reason can appear before confirmation.
    /// A swapped or expanded ID list is rejected and does not replace this preparation.
    @discardableResult
    func accept(_ review: TransactionMergeReview, for preparation: Preparation) -> Bool {
        let blockedAgrees = review.blockedReason == nil || !review.canSubmit
        guard isCurrent(preparation),
              !review.id.isEmpty,
              !review.reviewFingerprint.isEmpty,
              review.context == preparation.context,
              review.orderedTransactionIDs == preparation.orderedTransactionIDs,
              blockedAgrees else { return false }
        state = .reviewing(ReviewedMerge(selections: preparation.selections, review: review))
        return true
    }

    func failPreparation(_ preparation: Preparation, message: String) {
        guard isCurrent(preparation) else { return }
        state = .failed(
            context: preparation.context,
            message: message
        )
    }

    func cancelPreparation(_ preparation: Preparation) {
        guard isCurrent(preparation) else { return }
        invalidatePendingWork()
        state = .idle
    }

    func cancelReview() {
        guard case .reviewing = state else { return }
        state = .idle
    }

    func dismissFailure() {
        guard case .failed = state else { return }
        state = .idle
    }

    @discardableResult
    func beginSubmission() -> TransactionMergeReview? {
        guard case .reviewing(let reviewed) = state,
              reviewed.review.canSubmit,
              reviewed.review.blockedReason == nil else { return nil }
        state = .submitting(reviewed)
        return reviewed.review
    }

    /// Returns whether this review was the one in flight; stale completions change nothing.
    @discardableResult
    func completeSubmission(reviewID: String) -> Bool {
        guard case .submitting(let reviewed) = state, reviewed.review.id == reviewID else { return false }
        invalidatePendingWork()
        state = .idle
        return true
    }

    func failSubmission(reviewID: String, message: String) {
        guard case .submitting(let reviewed) = state, reviewed.review.id == reviewID else { return }
        state = .failed(
            context: reviewed.review.context,
            message: message
        )
    }

    func invalidate() {
        switch state {
        case .submitting:
            return
        case .idle, .preparing, .reviewing, .failed:
            invalidatePendingWork()
            state = .idle
        }
    }

    func cancelActive() {
        switch state {
        case .preparing(let preparation):
            cancelPreparation(preparation)
        case .reviewing:
            cancelReview()
        case .failed:
            dismissFailure()
        case .idle, .submitting:
            break
        }
    }

    private func invalidatePendingWork() {
        generation &+= 1
    }
}
