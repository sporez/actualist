import Foundation
import Observation

/// What a command supplies to the shared review state machine: how to read a
/// review, whether it echoes the prepared selections, and when it may submit.
protocol ReviewCommand {
    associatedtype Review: Equatable

    static func id(of review: Review) -> String
    static func fingerprint(of review: Review) -> String
    static func context(of review: Review) -> TransactionSelectionContext
    /// The command-specific acceptance rule, applied after the id, fingerprint
    /// and context checks every command shares.
    static func echoes(_ review: Review, selections: [TransactionSelectionIdentity]) -> Bool
    /// The extra gate on `beginSubmission`, applied to the accepted review.
    static func allowsSubmission(of review: Review) -> Bool
}

/// Review and commit for a selection command, in tap order. Selection itself
/// stays on `TransactionSelectionCoordinator`; this type owns the
/// idle/preparing/reviewing/submitting/failed lifecycle and drops any
/// preparation or completion that is not the current one.
@MainActor
@Observable
final class ReviewCommandCoordinator<Command: ReviewCommand> {
    struct Preparation: Hashable, Sendable, Identifiable {
        let id: UUID
        let generation: UInt64
        let context: TransactionSelectionContext
        let selections: [TransactionSelectionIdentity]

        var orderedTransactionIDs: [String] { selections.map(\.transactionID) }
    }

    enum State: Equatable {
        case idle
        case preparing(Preparation)
        case reviewing(Command.Review)
        case submitting(Command.Review)
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

    var review: Command.Review? {
        switch state {
        case .reviewing(let review), .submitting(let review): review
        case .idle, .preparing, .failed: nil
        }
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

    /// Accepts a review that echoes this preparation; a swapped or expanded
    /// selection list is rejected and does not replace the preparation. Each
    /// command decides whether a review that cannot be submitted is still
    /// shown, so the sheet can explain why before confirmation.
    @discardableResult
    func accept(_ review: Command.Review, for preparation: Preparation) -> Bool {
        guard isCurrent(preparation),
              !Command.id(of: review).isEmpty,
              !Command.fingerprint(of: review).isEmpty,
              Command.context(of: review) == preparation.context,
              Command.echoes(review, selections: preparation.selections) else { return false }
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
    func beginSubmission() -> Command.Review? {
        guard case .reviewing(let review) = state, Command.allowsSubmission(of: review) else { return nil }
        state = .submitting(review)
        return review
    }

    /// Returns whether this review was the one in flight; stale completions change nothing.
    @discardableResult
    func completeSubmission(reviewID: String) -> Bool {
        guard case .submitting(let review) = state, Command.id(of: review) == reviewID else { return false }
        invalidatePendingWork()
        state = .idle
        return true
    }

    func failSubmission(reviewID: String, message: String) {
        guard case .submitting(let review) = state, Command.id(of: review) == reviewID else { return }
        state = .failed(
            context: Command.context(of: review),
            message: message
        )
    }

    /// Drops an in-flight review without touching a submit.
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
