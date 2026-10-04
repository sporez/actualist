import Foundation
import Testing
@testable import Actualist

@MainActor
struct TransactionDuplicateCoordinatorTests {
    @Test func prepareReviewSubmitCancelAndFailPreserveTapOrder() throws {
        let coordinator = TransactionDuplicateCoordinator()
        let context = makeCommandContext()
        let first = try identity("first")
        let second = try identity("second")
        let selections = [first, second]

        let preparation = try #require(coordinator.beginPreparation(context: context, selections: selections))
        #expect(preparation.selections == selections)
        coordinator.cancelPreparation(preparation)
        #expect(coordinator.state == .idle)

        let again = try #require(coordinator.beginPreparation(context: context, selections: selections))
        let review = duplicateReview(context: context, selections: selections, groupIDs: [first.transactionID, second.transactionID])
        #expect(coordinator.accept(review, for: again))
        coordinator.cancelReview()
        #expect(coordinator.state == .idle)

        let submitting = try #require(coordinator.beginPreparation(context: context, selections: selections))
        #expect(coordinator.accept(review, for: submitting))
        let accepted = try #require(coordinator.beginSubmission())
        #expect(accepted.selections == selections)
        coordinator.failSubmission(reviewID: accepted.id, message: "The copy could not be saved.")
        #expect(coordinator.failureMessage == "The copy could not be saved.")
        #expect(failedSelections(coordinator) == selections)
        #expect(coordinator.hidesSelectionChrome == false)
    }

    @Test func stalePreparationCannotReplaceTheCurrentReview() throws {
        let coordinator = TransactionDuplicateCoordinator()
        let context = makeCommandContext()
        let first = try identity("first")
        let second = try identity("second")
        let stale = try #require(coordinator.beginPreparation(context: context, selections: [first]))
        coordinator.cancelPreparation(stale)
        let current = try #require(coordinator.beginPreparation(context: context, selections: [second]))
        let staleReview = duplicateReview(context: context, selections: [first], groupIDs: [first.transactionID])
        let currentReview = duplicateReview(
            context: context,
            selections: [second],
            groupIDs: [second.transactionID],
            id: "current"
        )

        #expect(coordinator.accept(staleReview, for: stale) == false)
        #expect(coordinator.isCurrent(current))
        coordinator.failPreparation(stale, message: "late")
        #expect(coordinator.accept(currentReview, for: current))
        guard case .reviewing(let review) = coordinator.state else {
            Issue.record("Expected the current review to remain")
            return
        }
        #expect(review.id == "current")
    }

    @Test func exactSelectionOrderIsRequired() throws {
        let coordinator = TransactionDuplicateCoordinator()
        let context = makeCommandContext()
        let first = try identity("first")
        let second = try identity("second")
        let preparation = try #require(coordinator.beginPreparation(context: context, selections: [first, second]))
        let swapped = duplicateReview(context: context, selections: [second, first], groupIDs: [first.transactionID, second.transactionID])
        let partial = duplicateReview(context: context, selections: [first, second], groupIDs: [first.transactionID])

        #expect(coordinator.accept(swapped, for: preparation) == false)
        #expect(coordinator.isCurrent(preparation))
        #expect(coordinator.accept(partial, for: preparation) == false)
        coordinator.failPreparation(preparation, message: "This selection changed. Review it again before continuing.")
        #expect(failedSelections(coordinator) == [first, second])
    }

    @Test func familyCollapsedReviewIsAcceptedWhenEverySelectionIsAccountedFor() throws {
        let coordinator = TransactionDuplicateCoordinator()
        let context = makeCommandContext()
        let parent = try identity("parent")
        let child = try identity("child", familyRootID: "parent", role: .child)
        let preparation = try #require(coordinator.beginPreparation(context: context, selections: [parent, child]))
        let review = duplicateReview(
            context: context,
            selections: [parent, child],
            groupIDs: [parent.transactionID, child.transactionID],
            singleGroup: true
        )

        #expect(coordinator.accept(review, for: preparation))
        #expect(coordinator.beginSubmission()?.selections == [parent, child])
    }

    @Test func lateDuplicateReviewDoesNotReplaceANewReview() async throws {
        let repository = DeferredDuplicateRepository(firstRequestFails: false)
        let presentation = TransactionBatchPresentation()
        let context = makeCommandContext()
        let snapshot = TransactionBatchFeedSnapshot(context: context)
        let first = transaction(id: "first")
        let second = transaction(id: "second")

        presentation.enter(context: context)
        presentation.toggle(first)
        let obsolete = try #require(presentation.prepareDuplicate(feedSnapshot: snapshot, repository: repository))
        guard await repository.waitForFirstRequest() else {
            obsolete.cancel()
            repository.releaseFirstRequest()
            await obsolete.value
            Issue.record("The first duplicate review did not reach its gate")
            return
        }

        presentation.cancelSheet()
        presentation.toggle(second)
        guard let current = presentation.prepareDuplicate(feedSnapshot: snapshot, repository: repository) else {
            repository.releaseFirstRequest()
            await obsolete.value
            Issue.record("Expected a new duplicate review")
            return
        }
        await current.value
        guard case .reviewing(let currentReview) = presentation.duplicate.state else {
            repository.releaseFirstRequest()
            await obsolete.value
            Issue.record("Expected the new request to reach review")
            return
        }

        repository.releaseFirstRequest()
        await obsolete.value
        #expect(presentation.commandSheet == .duplicate)
        #expect(presentation.duplicate.state == .reviewing(currentReview))
        #expect(presentation.selection.orderedSelectedIdentities.map(\.transactionID) == ["first", "second"])
    }

    @Test func duplicateFailurePreservesTheSelection() async throws {
        let repository = ThrowingDuplicateRepository()
        let presentation = TransactionBatchPresentation()
        let context = makeCommandContext()
        let snapshot = TransactionBatchFeedSnapshot(context: context)

        presentation.enter(context: context)
        presentation.toggle(transaction(id: "first"))
        presentation.toggle(transaction(id: "second"))
        let task = try #require(presentation.prepareDuplicate(feedSnapshot: snapshot, repository: repository))
        await task.value

        #expect(presentation.commandSheet == nil)
        #expect(presentation.isSelectionMode)
        #expect(presentation.selectionFailureMessage == "The duplicate review failed.")
        #expect(presentation.selection.orderedSelectedIdentities.map(\.transactionID) == ["first", "second"])
        #expect(failedSelections(presentation.duplicate)?.map(\.transactionID) == ["first", "second"])
    }
}

@MainActor
private final class DeferredDuplicateRepository: TransactionDuplicateRepositoryProtocol {
    private let firstRequestFails: Bool
    private let firstRequestEntered = TestLatch()
    private let releaseFirstRequestLatch = TestLatch()
    private var requestCount = 0

    init(firstRequestFails: Bool) {
        self.firstRequestFails = firstRequestFails
    }

    func waitForFirstRequest(timeout: Duration = .seconds(10)) async -> Bool {
        let reached = await firstRequestEntered.wait(timeout: timeout) { [releaseFirstRequestLatch] in
            releaseFirstRequestLatch.trip()
        }
        return requestCount > 0 && reached
    }

    func releaseFirstRequest() {
        releaseFirstRequestLatch.trip()
    }

    func reviewTransactionDuplicate(
        context: TransactionSelectionContext,
        selections: [TransactionSelectionIdentity]
    ) async throws -> TransactionDuplicateReview {
        requestCount += 1
        if requestCount == 1 {
            firstRequestEntered.trip()
            await releaseFirstRequestLatch.wait()
            if firstRequestFails { throw DuplicateReviewFailure.expected }
        }
        return duplicateReview(
            context: context,
            selections: selections,
            groupIDs: selections.map(\.transactionID),
            id: "review-\(selections.map(\.transactionID).joined(separator: "-"))"
        )
    }

    func commitTransactionDuplicate(
        review: TransactionDuplicateReview
    ) async throws -> TransactionDuplicateOutcome {
        Issue.record("Commit was not expected")
        throw DuplicateReviewFailure.expected
    }
}

@MainActor
private final class ThrowingDuplicateRepository: TransactionDuplicateRepositoryProtocol {
    func reviewTransactionDuplicate(
        context: TransactionSelectionContext,
        selections: [TransactionSelectionIdentity]
    ) async throws -> TransactionDuplicateReview {
        throw DuplicateReviewFailure.expected
    }

    func commitTransactionDuplicate(
        review: TransactionDuplicateReview
    ) async throws -> TransactionDuplicateOutcome {
        throw DuplicateReviewFailure.expected
    }
}

private enum DuplicateReviewFailure: LocalizedError {
    case expected

    var errorDescription: String? { "The duplicate review failed." }
}

private func duplicateReview(
    context: TransactionSelectionContext,
    selections: [TransactionSelectionIdentity],
    groupIDs: [String],
    id: String = "review",
    singleGroup: Bool = false
) -> TransactionDuplicateReview {
    let groups: [TransactionDuplicateGroupReview]
    if singleGroup {
        groups = [duplicateGroup(id: "family", selectedIDs: groupIDs)]
    } else {
        groups = groupIDs.map { duplicateGroup(id: $0, selectedIDs: [$0]) }
    }
    return TransactionDuplicateReview(
        id: id,
        context: context,
        selections: selections,
        groups: groups,
        allocations: groupIDs.map {
            TransactionDuplicateAllocation(sourceTransactionID: $0, duplicateTransactionID: "copy-\($0)", sortOrder: 1.5)
        },
        affectedResources: ChangedResources(accounts: ["checking"], months: ["2026-08"], transactions: groupIDs),
        reviewFingerprint: "fingerprint",
        canSubmit: true
    )
}

private func duplicateGroup(id: String, selectedIDs: [String]) -> TransactionDuplicateGroupReview {
    TransactionDuplicateGroupReview(
        id: id,
        selectedTransactionIDs: selectedIDs,
        sourceTransactionIDs: selectedIDs,
        duplicateTransactionIDs: selectedIDs.map { "copy-\($0)" },
        rows: selectedIDs.map { sourceID in
            TransactionDuplicateReviewRow(
                sourceTransactionID: sourceID,
                duplicateTransactionID: "copy-\(sourceID)",
                accountID: "checking",
                date: "2026-08-15",
                amountMinorUnits: -1_250,
                payeeID: nil,
                categoryID: nil,
                isParent: false,
                isChild: false,
                parentDuplicateTransactionID: nil,
                transferDuplicateTransactionID: nil
            )
        }
    )
}
