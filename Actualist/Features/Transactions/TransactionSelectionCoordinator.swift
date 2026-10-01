import Foundation
import Observation

@MainActor
@Observable
final class TransactionSelectionCoordinator {
    struct Preparation: Hashable, Sendable, Identifiable {
        let id: UUID
        let generation: UInt64
        let context: TransactionSelectionContext
        let intent: TransactionBatchIntent
        let selections: [TransactionSelectionIdentity]
    }

    enum State: Equatable {
        case inactive
        case selecting(context: TransactionSelectionContext, selections: TransactionOrderedSelection)
        case preparing(Preparation)
        case reviewing(TransactionBatchReview)
        case submitting(TransactionBatchReview)
        case committed(TransactionBatchOutcome)
        case failed(context: TransactionSelectionContext, selections: TransactionOrderedSelection, message: String)
    }

    private(set) var state: State = .inactive
    @ObservationIgnored private var generation: UInt64 = 0

    var selectedCount: Int {
        orderedSelectedIdentities.count
    }

    var isSubmitting: Bool {
        if case .submitting = state { return true }
        return false
    }

    var selectedIdentities: Set<TransactionSelectionIdentity> {
        Set(orderedSelectedIdentities)
    }

    var orderedSelectedIdentities: [TransactionSelectionIdentity] {
        switch state {
        case .selecting(_, let selections), .failed(_, let selections, _): selections.identities
        case .preparing(let preparation): preparation.selections
        case .reviewing(let review): review.selections
        case .submitting, .committed, .inactive: []
        }
    }

    func enter(context: TransactionSelectionContext) {
        guard !isSubmitting else { return }
        invalidatePendingWork()
        state = .selecting(context: context, selections: TransactionOrderedSelection())
    }

    @discardableResult
    func toggle(_ identity: TransactionSelectionIdentity) -> Bool {
        guard isValid(identity) else { return false }
        switch state {
        case .selecting(let context, var selections), .failed(let context, var selections, _):
            selections.toggle(identity)
            state = .selecting(context: context, selections: selections)
            return true
        default:
            return false
        }
    }

    func contextChanged(to context: TransactionSelectionContext) {
        guard !isSubmitting else { return }
        guard let current = activeContext, current != context else { return }
        invalidatePendingWork()
        state = .inactive
    }

    func exit() {
        guard !isSubmitting else { return }
        invalidatePendingWork()
        state = .inactive
    }

    func beginPreparation(for intent: TransactionBatchIntent) -> Preparation? {
        guard case .selecting(let context, let selections) = state,
              !selections.identities.isEmpty else { return nil }
        generation &+= 1
        let preparation = Preparation(
            id: UUID(),
            generation: generation,
            context: context,
            intent: intent,
            selections: selections.identities
        )
        state = .preparing(preparation)
        return preparation
    }

    @discardableResult
    func accept(_ review: TransactionBatchReview, for preparation: Preparation) -> Bool {
        let selected = Set(preparation.selections)
        let dispositionSelections = review.dispositions.map(\.selection)
        let authorizationRows = review.dispositions.compactMap { disposition -> TransactionBatchAuthorizationRequirement? in
            guard case .requiresAuthorization(let requirement) = disposition else { return nil }
            return requirement
        }
        let targetAuthorizationIDs = Set(authorizationRows.flatMap(\.reconciledTransactionIDs)).sorted()
        let pairedAuthorizationIDs = Set(authorizationRows.flatMap(\.pairedReconciledTransactionIDs)).sorted()
        let skippedIDs = review.skippedSelectionIDs
        let clearContractMatches: Bool
        switch preparation.intent {
        case .clear:
            let loadedIDs = Set(review.loadedUngroupedTransactionIDs)
            let loadedRows = review.rowSnapshots.filter { loadedIDs.contains($0.id) }
            let reviewedTarget = TransactionBatchClearTarget.fromLoadedRows(loadedRows)
            let rowsByID = Dictionary(
                review.rowSnapshots.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let targetIsConsistent = review.clearTarget == reviewedTarget
                || (review.clearTarget == nil
                    && reviewedTarget == nil
                    && review.blockedCount > 0
                    && !review.canSubmit)
            clearContractMatches = targetIsConsistent
                && Set(skippedIDs).count == skippedIDs.count
                && Set(skippedIDs).isSubset(of: Set(selected.map(\.transactionID)))
                && skippedIDs.allSatisfy { rowsByID[$0]?.reconciled == true }
        case .categorize, .delete:
            clearContractMatches = review.clearTarget == nil && skippedIDs.isEmpty
        }
        let authorizationMatches: Bool
        if targetAuthorizationIDs.isEmpty && pairedAuthorizationIDs.isEmpty {
            authorizationMatches = review.authorization == nil
        } else {
            authorizationMatches = review.authorization.map {
                $0.reviewID == review.id
                    && $0.reviewFingerprint == review.reviewFingerprint
                    && $0.reconciledTransactionIDs == targetAuthorizationIDs
                    && $0.pairedReconciledTransactionIDs == pairedAuthorizationIDs
            } ?? false
        }
        guard case .preparing(let current) = state,
              current == preparation,
              generation == preparation.generation,
              !review.id.isEmpty,
              !review.reviewFingerprint.isEmpty,
              review.context == preparation.context,
              review.intent == preparation.intent,
              review.selections == preparation.selections,
              review.selections.count == selected.count,
              Set(dispositionSelections) == selected,
              dispositionSelections.count == selected.count,
              clearContractMatches,
              !review.canSubmit || review.actionableCount > 0,
              review.blockedCount == 0 || !review.canSubmit,
              authorizationMatches else { return false }
        state = .reviewing(review)
        return true
    }

    func failPreparation(_ preparation: Preparation, message: String) {
        guard case .preparing(let current) = state, current == preparation,
              generation == preparation.generation else { return }
        state = .failed(
            context: preparation.context,
            selections: TransactionOrderedSelection(preparation.selections),
            message: message
        )
    }

    func cancelPreparation(_ preparation: Preparation) {
        guard case .preparing(let current) = state, current == preparation,
              generation == preparation.generation else { return }
        invalidatePendingWork()
        state = .selecting(context: preparation.context, selections: TransactionOrderedSelection(preparation.selections))
    }

    func cancelReview() {
        guard case .reviewing(let review) = state else { return }
        state = .selecting(context: review.context, selections: TransactionOrderedSelection(review.selections))
    }

    @discardableResult
    func beginSubmission() -> TransactionBatchReview? {
        guard case .reviewing(let review) = state,
              review.canSubmit,
              review.blockedCount == 0 else { return nil }
        state = .submitting(review)
        return review
    }

    func completeSubmission(reviewID: String, result: TransactionBatchOutcome) {
        guard case .submitting(let review) = state, review.id == reviewID else { return }
        state = .committed(result)
    }

    func failSubmission(reviewID: String, message: String) {
        guard case .submitting(let review) = state, review.id == reviewID else { return }
        state = .failed(
            context: review.context,
            selections: TransactionOrderedSelection(review.selections),
            message: message
        )
    }

    func finishCommittedResult() {
        guard case .committed = state else { return }
        invalidatePendingWork()
        state = .inactive
    }

    private var activeContext: TransactionSelectionContext? {
        switch state {
        case .selecting(let context, _), .failed(let context, _, _): context
        case .preparing(let preparation): preparation.context
        case .reviewing(let review), .submitting(let review): review.context
        case .inactive, .committed: nil
        }
    }

    private func invalidatePendingWork() {
        generation &+= 1
    }

    private func isValid(_ identity: TransactionSelectionIdentity) -> Bool {
        !identity.transactionID.isEmpty && !identity.familyRootID.isEmpty
    }
}
