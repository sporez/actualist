import Foundation
import Observation

/// Duplicate review and commit for every selected row, in tap order.
/// Selection itself stays on `TransactionSelectionCoordinator`; this type only
/// copies that order for the command and rejects a review that does not echo it.
@MainActor
@Observable
final class TransactionDuplicateCoordinator {
    struct Preparation: Hashable, Sendable, Identifiable {
        let id: UUID
        let generation: UInt64
        let context: TransactionSelectionContext
        let selections: [TransactionSelectionIdentity]
    }

    enum State: Equatable {
        case idle
        case preparing(Preparation)
        case reviewing(TransactionDuplicateReview)
        case submitting(TransactionDuplicateReview)
        case committed(TransactionDuplicateOutcome)
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

    var isCommitted: Bool {
        if case .committed = state { return true }
        return false
    }

    var hidesSelectionChrome: Bool {
        switch state {
        case .preparing, .reviewing, .submitting, .committed: true
        case .idle, .failed: false
        }
    }

    var failureMessage: String? {
        if case .failed(_, let message) = state { return message }
        return nil
    }

    @discardableResult
    func beginPreparation(
        context: TransactionSelectionContext,
        selections: [TransactionSelectionIdentity]
    ) -> Preparation? {
        switch state {
        case .idle, .failed:
            break
        case .preparing, .reviewing, .submitting, .committed:
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

    /// Accepts only a review whose selections are the exact prepared order.
    /// A submittable review must also account for every selection in its groups.
    /// A non-submittable review is still accepted so the sheet can explain why
    /// before confirmation. A reordered echo is not accepted.
    @discardableResult
    func accept(_ review: TransactionDuplicateReview, for preparation: Preparation) -> Bool {
        let groupedIDs = review.groups.flatMap(\.selectedTransactionIDs)
        let preparedIDs = preparation.selections.map(\.transactionID)
        let groupsAccountForSelections = Set(groupedIDs).count == groupedIDs.count
            && Set(groupedIDs) == Set(preparedIDs)
        guard isCurrent(preparation),
              !review.id.isEmpty,
              !review.reviewFingerprint.isEmpty,
              review.context == preparation.context,
              review.selections == preparation.selections,
              review.canSubmit ? groupsAccountForSelections && !review.groups.isEmpty : true else { return false }
        state = .reviewing(review)
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
    func beginSubmission() -> TransactionDuplicateReview? {
        guard case .reviewing(let review) = state, review.canSubmit else { return nil }
        state = .submitting(review)
        return review
    }

    func completeSubmission(reviewID: String, result: TransactionDuplicateOutcome) {
        guard case .submitting(let review) = state, review.id == reviewID else { return }
        state = .committed(result)
    }

    func failSubmission(reviewID: String, message: String) {
        guard case .submitting(let review) = state, review.id == reviewID else { return }
        state = .failed(
            context: review.context,
            message: message
        )
    }

    func finishCommittedResult() {
        guard case .committed = state else { return }
        invalidatePendingWork()
        state = .idle
    }

    /// Drops an in-flight review without touching a submit or a saved result.
    func invalidate() {
        switch state {
        case .submitting, .committed:
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
        case .committed:
            finishCommittedResult()
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
