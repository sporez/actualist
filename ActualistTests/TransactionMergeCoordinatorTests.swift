import Foundation
import Testing
@testable import Actualist

@MainActor
struct TransactionMergeCoordinatorTests {
    @Test func prepareReviewSubmitCancelAndFailPreserveTapOrder() throws {
        let coordinator = TransactionMergeCoordinator()
        let context = makeCommandContext()
        let first = try identity("first")
        let second = try identity("second")
        let selections = [first, second]

        let preparation = try #require(coordinator.beginPreparation(context: context, selections: selections))
        #expect(preparation.orderedTransactionIDs == ["first", "second"])
        coordinator.cancelPreparation(preparation)
        #expect(coordinator.state == .idle)

        let again = try #require(coordinator.beginPreparation(context: context, selections: selections))
        let review = mergeReview(context: context, orderedIDs: ["first", "second"])
        #expect(coordinator.accept(review, for: again))
        coordinator.cancelReview()

        let submitting = try #require(coordinator.beginPreparation(context: context, selections: selections))
        #expect(coordinator.accept(review, for: submitting))
        #expect(coordinator.beginSubmission()?.orderedTransactionIDs == ["first", "second"])
        coordinator.failSubmission(reviewID: review.id, message: "The merge could not be saved.")
        #expect(failedSelections(coordinator) == selections)
        #expect(coordinator.failureMessage == "The merge could not be saved.")
    }

    @Test func swappedReviewOrderIsRejectedAndFailureKeepsThePreparedOrder() throws {
        let coordinator = TransactionMergeCoordinator()
        let context = makeCommandContext()
        let first = try identity("later")
        let second = try identity("earlier")
        let preparation = try #require(coordinator.beginPreparation(context: context, selections: [first, second]))
        let swapped = mergeReview(context: context, orderedIDs: ["earlier", "later"])

        #expect(coordinator.accept(swapped, for: preparation) == false)
        #expect(coordinator.isCurrent(preparation))
        coordinator.failPreparation(preparation, message: "This selection changed. Review it again before continuing.")
        #expect(failedSelections(coordinator)?.map(\.transactionID) == ["later", "earlier"])
    }

    @Test func staleMergeResultCannotReplaceTheCurrentReview() throws {
        let coordinator = TransactionMergeCoordinator()
        let context = makeCommandContext()
        let first = try identity("first")
        let second = try identity("second")
        let stale = try #require(coordinator.beginPreparation(context: context, selections: [first, second]))
        coordinator.cancelPreparation(stale)
        let current = try #require(coordinator.beginPreparation(context: context, selections: [second, first]))
        let staleReview = mergeReview(context: context, orderedIDs: ["first", "second"], id: "stale")
        let currentReview = mergeReview(context: context, orderedIDs: ["second", "first"], id: "current")

        #expect(coordinator.accept(staleReview, for: stale) == false)
        coordinator.failPreparation(stale, message: "late")
        #expect(coordinator.accept(currentReview, for: current))
        #expect(coordinator.review?.id == "current")
        #expect(coordinator.review?.orderedTransactionIDs == ["second", "first"])
    }

    @Test func blockedReviewIsAcceptedButCannotBeSubmitted() throws {
        let coordinator = TransactionMergeCoordinator()
        let context = makeCommandContext()
        let child = try identity("child", familyRootID: "parent", role: .child)
        let other = try identity("other")
        let preparation = try #require(coordinator.beginPreparation(context: context, selections: [child, other]))
        let review = mergeReview(
            context: context,
            orderedIDs: ["child", "other"],
            blocked: .selectedChild("child"),
            kept: nil,
            dropped: nil
        )

        #expect(coordinator.accept(review, for: preparation))
        #expect(coordinator.beginSubmission() == nil)
        #expect(coordinator.review?.blockedReason == .selectedChild("child"))
    }

    @Test func reconciledAuthorizationMatchesTheReviewExactly() throws {
        let review = mergeReview(
            context: makeCommandContext(),
            orderedIDs: ["first", "second"],
            reconciledIDs: ["second", "first"]
        )
        let authorization = TransactionMergeCoordinator.authorization(for: review)
        #expect(authorization == TransactionMergeAuthorization(
            reviewID: review.id,
            reviewFingerprint: review.reviewFingerprint,
            reconciledTransactionIDs: ["second", "first"]
        ))
        #expect(TransactionMergeCoordinator.authorization(
            for: mergeReview(context: makeCommandContext(), orderedIDs: ["first", "second"])
        ) == nil)
    }

    @Test func confirmPassesTheExactReconciledAuthorization() async throws {
        let repository = RecordingMergeRepository()
        let presentation = TransactionBatchPresentation()
        let context = makeCommandContext()
        let snapshot = TransactionBatchFeedSnapshot(context: context)
        presentation.enter(context: context)
        presentation.toggle(transaction(id: "first"))
        presentation.toggle(transaction(id: "second"))
        repository.review = mergeReview(
            context: context,
            orderedIDs: ["first", "second"],
            reconciledIDs: ["paired", "first"]
        )

        let task = try #require(presentation.prepareMerge(feedSnapshot: snapshot, repository: repository))
        await task.value
        presentation.confirmMerge(
            repository: repository,
            currentFeedSnapshot: { snapshot },
            onCommitted: { _ in }
        )
        await repository.waitForCommit()

        #expect(repository.authorization == TransactionMergeAuthorization(
            reviewID: "review",
            reviewFingerprint: "fingerprint",
            reconciledTransactionIDs: ["paired", "first"]
        ))
    }

    @Test func mergeFailurePreservesTapOrder() async throws {
        let repository = ThrowingMergeRepository()
        let presentation = TransactionBatchPresentation()
        let context = makeCommandContext()
        let snapshot = TransactionBatchFeedSnapshot(context: context)
        presentation.enter(context: context)
        presentation.toggle(transaction(id: "second"))
        presentation.toggle(transaction(id: "first"))
        let task = try #require(presentation.prepareMerge(feedSnapshot: snapshot, repository: repository))
        await task.value

        #expect(presentation.isSelectionMode)
        #expect(presentation.selection.orderedSelectedIdentities.map(\.transactionID) == ["second", "first"])
        #expect(failedSelections(presentation.merge)?.map(\.transactionID) == ["second", "first"])
        #expect(presentation.selectionFailureMessage == "The merge review failed.")
    }
}

@MainActor
private final class RecordingMergeRepository: TransactionMergeRepositoryProtocol {
    var review = mergeReview(context: makeCommandContext(), orderedIDs: [])
    private(set) var authorization: TransactionMergeAuthorization?
    private let committed = TestLatch()

    func reviewTransactionMerge(
        context: TransactionSelectionContext,
        orderedTransactionIDs: [String]
    ) async throws -> TransactionMergeReview {
        review
    }

    func commitTransactionMerge(
        review: TransactionMergeReview,
        authorization: TransactionMergeAuthorization?
    ) async throws -> TransactionMergeOutcome {
        self.authorization = authorization
        committed.trip()
        return TransactionMergeOutcome(
            receipt: TransactionMergeReceipt(
                changedAccountIDs: ["checking"],
                changedMonths: ["2026-08"],
                changedTransactionIDs: review.orderedTransactionIDs,
                actionID: "action"
            ),
            refreshPending: false,
            sessionCurrent: true
        )
    }

    func waitForCommit() async {
        await committed.wait()
    }
}

@MainActor
private final class ThrowingMergeRepository: TransactionMergeRepositoryProtocol {
    func reviewTransactionMerge(
        context: TransactionSelectionContext,
        orderedTransactionIDs: [String]
    ) async throws -> TransactionMergeReview {
        throw MergeReviewFailure.expected
    }

    func commitTransactionMerge(
        review: TransactionMergeReview,
        authorization: TransactionMergeAuthorization?
    ) async throws -> TransactionMergeOutcome {
        throw MergeReviewFailure.expected
    }
}

private enum MergeReviewFailure: LocalizedError {
    case expected

    var errorDescription: String? { "The merge review failed." }
}

private func mergeReview(
    context: TransactionSelectionContext,
    orderedIDs: [String],
    id: String = "review",
    blocked: TransactionMergeBlockedReason? = nil,
    kept: TransactionMergeReviewRow? = nil,
    dropped: TransactionMergeReviewRow? = nil,
    reconciledIDs: [String] = []
) -> TransactionMergeReview {
    let keptRow = blocked == nil ? (kept ?? mergeRow(id: orderedIDs.first ?? "kept")) : kept
    let droppedRow = blocked == nil ? (dropped ?? mergeRow(id: orderedIDs.dropFirst().first ?? "dropped")) : dropped
    return TransactionMergeReview(
        id: id,
        context: context,
        orderedTransactionIDs: orderedIDs,
        keptRow: keptRow,
        droppedRow: droppedRow,
        fieldEffects: [],
        childMovements: [],
        transferDisposition: .none,
        reciprocalTransferPairs: [],
        tombstonedTransactionIDs: droppedRow.map { [$0.transactionID] } ?? [],
        tombstonedPeerIDs: [],
        affectedResources: TransactionMergeAffectedResources(
            changed: ChangedResources(accounts: ["checking"], months: ["2026-08"], transactions: orderedIDs),
            payeeIDs: [],
            categoryIDs: []
        ),
        blockedReason: blocked,
        reconciledTransactionIDs: reconciledIDs,
        reviewFingerprint: "fingerprint"
    )
}

private func mergeRow(id: String, amount: Int = -1_250, notes: String? = nil) -> TransactionMergeReviewRow {
    TransactionMergeReviewRow(
        transactionID: id,
        accountID: "checking",
        date: "2026-08-15",
        amountMinorUnits: amount,
        payeeID: nil,
        categoryID: nil,
        notes: notes,
        cleared: true,
        reconciled: false,
        isParent: false,
        isChild: false,
        isTransfer: false
    )
}
