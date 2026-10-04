import Foundation
import Testing
@testable import Actualist

@MainActor
struct TransactionSelectionCoordinatorTests {
    @Test func selectionRequiresPersistedIDsAndRetainsPhysicalChildIdentity() throws {
        let coordinator = TransactionSelectionCoordinator()
        let context = makeContext()
        coordinator.enter(context: context)

        #expect(TransactionSelectionIdentity(transactionID: nil, familyRootID: "root", role: .root) == nil)
        #expect(TransactionSelectionIdentity(transactionID: "child", familyRootID: nil, role: .child) == nil)

        let child = try #require(TransactionSelectionIdentity(
            transactionID: "child",
            familyRootID: "root",
            role: .child
        ))
        #expect(coordinator.toggle(child))
        #expect(coordinator.selectedIdentities == [child])
        #expect(child.familyRootID == "root")
        #expect(child.role == .child)
    }

    @Test func transactionProjectionUsesOnlyPersistedFamilyIdentity() throws {
        let child = ActualTransaction(
            id: "child",
            account: "account",
            date: "2026-09-01",
            amount: -100,
            payee: nil,
            payeeName: nil,
            importedPayee: nil,
            category: nil,
            notes: nil,
            cleared: nil,
            isChild: true,
            parentID: "root"
        )
        let identity = try #require(TransactionSelectionIdentity(transaction: child))
        #expect(identity.transactionID == "child")
        #expect(identity.familyRootID == "root")
        #expect(identity.role == .child)

        let transient = ActualTransaction(
            id: nil,
            account: "account",
            date: "2026-09-01",
            amount: -100,
            payee: nil,
            payeeName: nil,
            importedPayee: nil,
            category: nil,
            notes: nil,
            cleared: nil
        )
        #expect(TransactionSelectionIdentity(transaction: transient) == nil)
    }

    @Test func parentAndChildRemainDistinctExplicitSelections() throws {
        let coordinator = TransactionSelectionCoordinator()
        coordinator.enter(context: makeContext())
        let parent = try #require(TransactionSelectionIdentity(
            transactionID: "root",
            familyRootID: "root",
            role: .root
        ))
        let child = try #require(TransactionSelectionIdentity(
            transactionID: "child",
            familyRootID: "root",
            role: .child
        ))

        #expect(coordinator.toggle(parent))
        #expect(coordinator.toggle(child))
        #expect(coordinator.selectedCount == 2)
        #expect(coordinator.selectedIdentities == [parent, child])
    }

    @Test func repeatedPhysicalIDCannotCreateSecondSelectionIdentity() throws {
        let coordinator = TransactionSelectionCoordinator()
        coordinator.enter(context: makeContext())
        let original = try #require(TransactionSelectionIdentity(
            transactionID: "txn",
            familyRootID: "root",
            role: .child
        ))
        let moved = try #require(TransactionSelectionIdentity(
            transactionID: "txn",
            familyRootID: "txn",
            role: .root
        ))

        #expect(coordinator.toggle(original))
        #expect(coordinator.toggle(moved))
        #expect(coordinator.selectedIdentities.isEmpty)
    }

    @Test func budgetScopeOrQueryChangeExitsSelection() throws {
        let coordinator = TransactionSelectionCoordinator()
        let initial = makeContext()
        coordinator.enter(context: initial)
        let identity = try #require(TransactionSelectionIdentity(
            transactionID: "txn",
            familyRootID: "txn",
            role: .root
        ))
        #expect(coordinator.toggle(identity))

        coordinator.contextChanged(to: TransactionSelectionContext(
            budgetID: "other-budget",
            sessionGeneration: 0,
            scope: .spending,
            querySignature: TransactionFeedQuery().signature
        ))
        #expect(coordinator.state == .inactive)

        coordinator.enter(context: initial)
        #expect(coordinator.toggle(identity))
        coordinator.contextChanged(to: initial)
        #expect(coordinator.selectedIdentities == [identity])
        coordinator.contextChanged(to: TransactionSelectionContext(
            budgetID: initial.budgetID,
            sessionGeneration: initial.sessionGeneration,
            scope: .spending,
            querySignature: TransactionFeedQuery(status: .cleared).signature
        ))
        #expect(coordinator.state == .inactive)

        let scoped = TransactionSelectionContext(
            budgetID: initial.budgetID,
            sessionGeneration: initial.sessionGeneration,
            scope: .account("checking"),
            querySignature: initial.querySignature
        )
        coordinator.enter(context: initial)
        #expect(coordinator.toggle(identity))
        coordinator.contextChanged(to: scoped)
        #expect(coordinator.state == .inactive)
    }

    @Test func sessionGenerationChangeExitsSelection() throws {
        let coordinator = TransactionSelectionCoordinator()
        let context = makeContext()
        coordinator.enter(context: context)
        let identity = try #require(TransactionSelectionIdentity(
            transactionID: "txn", familyRootID: "txn", role: .root
        ))
        #expect(coordinator.toggle(identity))

        coordinator.contextChanged(to: TransactionSelectionContext(
            budgetID: context.budgetID,
            sessionGeneration: context.sessionGeneration + 1,
            scope: context.scope,
            querySignature: context.querySignature
        ))
        #expect(coordinator.state == .inactive)
    }

    @Test func lateReviewIsRejectedAfterSelectionExit() throws {
        let coordinator = TransactionSelectionCoordinator()
        coordinator.enter(context: makeContext())
        let identity = try #require(TransactionSelectionIdentity(
            transactionID: "txn",
            familyRootID: "txn",
            role: .root
        ))
        #expect(coordinator.toggle(identity))
        let preparation = try #require(coordinator.beginPreparation(for: .delete))
        coordinator.exit()

        #expect(!coordinator.accept(makeReview(for: preparation), for: preparation))
        #expect(coordinator.state == .inactive)
    }

    @Test func reviewMustPartitionExactlyTheSelectedRows() throws {
        let coordinator = TransactionSelectionCoordinator()
        coordinator.enter(context: makeContext())
        let first = try #require(TransactionSelectionIdentity(
            transactionID: "first",
            familyRootID: "first",
            role: .root
        ))
        let second = try #require(TransactionSelectionIdentity(
            transactionID: "second",
            familyRootID: "second",
            role: .root
        ))
        #expect(coordinator.toggle(first))
        #expect(coordinator.toggle(second))
        let preparation = try #require(coordinator.beginPreparation(for: .clear))
        var incompleteReview = makeReview(for: preparation)
        incompleteReview = TransactionBatchReview(
            id: incompleteReview.id,
            context: incompleteReview.context,
            intent: incompleteReview.intent,
            selections: incompleteReview.selections,
            dispositions: Array(incompleteReview.dispositions.dropLast()),
            rowChanges: incompleteReview.rowChanges,
            metadata: incompleteReview.metadata,
            clearTarget: incompleteReview.clearTarget,
            reviewFingerprint: incompleteReview.reviewFingerprint,
            effectsDescription: incompleteReview.effectsDescription,
            authorization: nil,
            canSubmit: true
        )

        #expect(!coordinator.accept(incompleteReview, for: preparation))
        #expect(coordinator.state == .preparing(preparation))
    }

    @Test func blockedDispositionCannotAuthorizeAnyPartOfBatch() throws {
        let coordinator = TransactionSelectionCoordinator()
        coordinator.enter(context: makeContext())
        let first = try #require(TransactionSelectionIdentity(
            transactionID: "first",
            familyRootID: "first",
            role: .root
        ))
        let second = try #require(TransactionSelectionIdentity(
            transactionID: "second",
            familyRootID: "second",
            role: .root
        ))
        #expect(coordinator.toggle(first))
        #expect(coordinator.toggle(second))
        let preparation = try #require(coordinator.beginPreparation(for: .delete))
        let allowedSubset = makeReview(for: preparation)
        let blockedReview = TransactionBatchReview(
            id: allowedSubset.id,
            context: allowedSubset.context,
            intent: allowedSubset.intent,
            selections: allowedSubset.selections,
            dispositions: [
                allowedSubset.dispositions[0],
                .blocked(TransactionBatchDispositionReason(
                    selection: second,
                    explanation: "The selected transaction graph needs repair."
                )),
            ],
            rowChanges: allowedSubset.rowChanges,
            metadata: allowedSubset.metadata,
            clearTarget: nil,
            reviewFingerprint: allowedSubset.reviewFingerprint,
            effectsDescription: "The whole batch is blocked.",
            authorization: nil,
            canSubmit: false
        )

        #expect(coordinator.accept(blockedReview, for: preparation))
        #expect(coordinator.beginSubmission() == nil)
    }

    @Test func clearReviewRejectsSkippedIDsOutsideSelection() throws {
        let coordinator = TransactionSelectionCoordinator()
        coordinator.enter(context: makeContext())
        let identity = try #require(TransactionSelectionIdentity(
            transactionID: "reconciled",
            familyRootID: "reconciled",
            role: .root
        ))
        #expect(coordinator.toggle(identity))
        let preparation = try #require(coordinator.beginPreparation(for: .clear))
        let foreign = try #require(TransactionSelectionIdentity(
            transactionID: "not-selected",
            familyRootID: "not-selected",
            role: .root
        ))
        let outsideSkip = TransactionBatchReview(
            id: preparation.id.uuidString,
            context: preparation.context,
            intent: .clear,
            selections: preparation.selections,
            dispositions: [
                .eligible(TransactionBatchEffectSummary(
                    selection: identity,
                    affectedTransactionIDs: [identity.transactionID],
                    description: "One row would be changed."
                )),
                .skipped(TransactionBatchDispositionReason(
                    selection: foreign,
                    explanation: "This row was not selected."
                )),
            ],
            rowChanges: preparation.selections.map {
                let snapshot = makeRowSnapshot(id: $0.transactionID, cleared: false)
                return TransactionBatchRowChange(before: snapshot, after: snapshot)
            },
            metadata: reviewMetadata,
            clearTarget: true,
            reviewFingerprint: "fingerprint",
            effectsDescription: "One row would be changed.",
            authorization: nil,
            canSubmit: true
        )

        #expect(!coordinator.accept(outsideSkip, for: preparation))
        #expect(coordinator.state == .preparing(preparation))
    }

    @Test func clearTargetMatchesPinnedSourceToggleRuleAndRejectsMissingState() {
        func root(_ id: String) -> TransactionSelectionIdentity {
            TransactionSelectionIdentity(transactionID: id, familyRootID: id, role: .root)!
        }
        #expect(TransactionBatchClearTarget.fromSelection([root("a"), root("b")], rows: [
            makeRowSnapshot(id: "a", cleared: true),
            makeRowSnapshot(id: "b", cleared: true),
        ]) == false)
        #expect(TransactionBatchClearTarget.fromSelection([root("a"), root("b")], rows: [
            makeRowSnapshot(id: "a", cleared: false),
            makeRowSnapshot(id: "b", cleared: true),
        ]) == true)
        #expect(TransactionBatchClearTarget.fromSelection([root("a")], rows: [
            makeRowSnapshot(id: "a", cleared: nil),
        ]) == nil)
        #expect(TransactionBatchClearTarget.fromSelection([root("a")], rows: []) == nil)
    }

    @Test func clearTargetIgnoresUnselectedRowsAndUsesTheSelectedFamily() {
        let parent = TransactionSelectionIdentity(transactionID: "p", familyRootID: "p", role: .root)!
        let child = TransactionSelectionIdentity(transactionID: "c1", familyRootID: "p", role: .child)!
        let rows = [
            makeRowSnapshot(id: "p", cleared: true),
            makeRowSnapshot(id: "c1", cleared: true, parentID: "p"),
            makeRowSnapshot(id: "c2", cleared: false, parentID: "p"),
            makeRowSnapshot(id: "other", cleared: false),
        ]
        #expect(TransactionBatchClearTarget.fromSelection([parent], rows: rows) == true)
        #expect(TransactionBatchClearTarget.fromSelection([child], rows: rows) == true)
        #expect(TransactionBatchClearTarget.fromSelection([parent], rows: Array(rows.prefix(2) + [rows[3]])) == false)
    }

    @Test func contextChangeDoesNotDiscardInFlightCommitResult() throws {
        let coordinator = TransactionSelectionCoordinator()
        let originalContext = makeContext()
        coordinator.enter(context: originalContext)
        let identity = try #require(TransactionSelectionIdentity(
            transactionID: "txn",
            familyRootID: "txn",
            role: .root
        ))
        #expect(coordinator.toggle(identity))
        let preparation = try #require(coordinator.beginPreparation(for: .delete))
        let review = makeReview(for: preparation)
        #expect(coordinator.accept(review, for: preparation))
        #expect(coordinator.beginSubmission() == review)

        coordinator.contextChanged(to: TransactionSelectionContext(
            budgetID: "next-budget",
            sessionGeneration: 0,
            scope: .spending,
            querySignature: TransactionFeedQuery().signature
        ))
        #expect(coordinator.isSubmitting)
        let result = TransactionBatchResult(
            changedAccountIDs: ["account"],
            changedMonthIDs: ["2026-09"],
            changedTransactionIDs: ["txn"],
            actionID: "action"
        )
        let outcome = TransactionBatchOutcome(receipt: result, refreshPending: true, sessionCurrent: false)
        coordinator.completeSubmission(reviewID: review.id, result: outcome)
        #expect(coordinator.state == .committed(outcome))
    }

    @Test func cancellingReviewReturnsToSelectionAndFailedSubmitRetainsIt() throws {
        let coordinator = TransactionSelectionCoordinator()
        coordinator.enter(context: makeContext())
        let identity = try #require(TransactionSelectionIdentity(
            transactionID: "txn",
            familyRootID: "txn",
            role: .root
        ))
        #expect(coordinator.toggle(identity))
        let preparation = try #require(coordinator.beginPreparation(for: .delete))
        let review = makeReview(for: preparation)
        #expect(coordinator.accept(review, for: preparation))
        coordinator.cancelReview()
        #expect(coordinator.selectedIdentities == [identity])

        let retry = try #require(coordinator.beginPreparation(for: .delete))
        let retryReview = makeReview(for: retry)
        #expect(coordinator.accept(retryReview, for: retry))
        #expect(coordinator.beginSubmission() == retryReview)
        coordinator.failSubmission(reviewID: retryReview.id, message: "Could not save")
        #expect(coordinator.selectedIdentities == [identity])
        if case .failed(_, _, let message) = coordinator.state {
            #expect(message == "Could not save")
        } else {
            Issue.record("Expected retryable failure state")
        }
    }

    @Test func tapOrderSurvivesPreparationCancellationAndRetryableFailures() throws {
        let coordinator = TransactionSelectionCoordinator()
        coordinator.enter(context: makeContext())
        let lastAlphabetically = try #require(TransactionSelectionIdentity(
            transactionID: "z", familyRootID: "z", role: .root
        ))
        let firstAlphabetically = try #require(TransactionSelectionIdentity(
            transactionID: "a", familyRootID: "a", role: .root
        ))
        let ordered = [lastAlphabetically, firstAlphabetically]
        for identity in ordered { #expect(coordinator.toggle(identity)) }
        #expect(coordinator.orderedSelectedIdentities == ordered)
        #expect(coordinator.selectedIdentities == Set(ordered))

        let canceled = try #require(coordinator.beginPreparation(for: .delete))
        #expect(canceled.selections == ordered)
        coordinator.cancelPreparation(canceled)
        #expect(coordinator.orderedSelectedIdentities == ordered)

        let failed = try #require(coordinator.beginPreparation(for: .delete))
        coordinator.failPreparation(failed, message: "Review unavailable")
        #expect(coordinator.orderedSelectedIdentities == ordered)
        #expect(!coordinator.accept(makeReview(for: canceled), for: canceled))
        #expect(coordinator.orderedSelectedIdentities == ordered)

        // Removing and reselecting a row makes it the new second input.
        #expect(coordinator.toggle(lastAlphabetically))
        #expect(coordinator.toggle(lastAlphabetically))
        let reselected = [firstAlphabetically, lastAlphabetically]
        #expect(coordinator.orderedSelectedIdentities == reselected)
        let preparation = try #require(coordinator.beginPreparation(for: .delete))
        let review = makeReview(for: preparation)
        #expect(coordinator.accept(review, for: preparation))
        coordinator.cancelReview()
        #expect(coordinator.orderedSelectedIdentities == reselected)

        let retry = try #require(coordinator.beginPreparation(for: .delete))
        let retryReview = makeReview(for: retry)
        #expect(coordinator.accept(retryReview, for: retry))
        #expect(coordinator.beginSubmission() == retryReview)
        coordinator.failSubmission(reviewID: retryReview.id, message: "Could not save")
        #expect(coordinator.orderedSelectedIdentities == reselected)
        coordinator.exit()
        #expect(coordinator.orderedSelectedIdentities.isEmpty)
    }

    @Test func reviewCannotReverseOrderedInputs() throws {
        let coordinator = TransactionSelectionCoordinator()
        coordinator.enter(context: makeContext())
        let first = try #require(TransactionSelectionIdentity(
            transactionID: "z", familyRootID: "z", role: .root
        ))
        let second = try #require(TransactionSelectionIdentity(
            transactionID: "a", familyRootID: "a", role: .root
        ))
        #expect(coordinator.toggle(first))
        #expect(coordinator.toggle(second))
        let preparation = try #require(coordinator.beginPreparation(for: .delete))
        let reversed = makeReview(for: preparation, selections: [second, first])
        #expect(!coordinator.accept(reversed, for: preparation))
        #expect(coordinator.state == .preparing(preparation))
        #expect(coordinator.orderedSelectedIdentities == [first, second])
    }

    @Test func orderedSelectionDeduplicatesPhysicalRowsWithoutReorderingFamilies() throws {
        let child = try #require(TransactionSelectionIdentity(
            transactionID: "child", familyRootID: "root", role: .child
        ))
        let root = try #require(TransactionSelectionIdentity(
            transactionID: "root", familyRootID: "root", role: .root
        ))
        let movedChild = try #require(TransactionSelectionIdentity(
            transactionID: "child", familyRootID: "child", role: .root
        ))
        var selection = TransactionOrderedSelection([child, root, movedChild, root])
        #expect(selection.identities == [child, root])
        selection.toggle(movedChild)
        #expect(selection.identities == [root])
        selection.toggle(movedChild)
        #expect(selection.identities == [root, movedChild])
    }

    private func makeContext() -> TransactionSelectionContext {
        TransactionSelectionContext(
            budgetID: "budget",
            sessionGeneration: 0,
            scope: .spending,
            querySignature: TransactionFeedQuery().signature
        )
    }

    private func makeReview(
        for preparation: TransactionSelectionCoordinator.Preparation,
        selections: [TransactionSelectionIdentity]? = nil
    ) -> TransactionBatchReview {
        let selections = selections ?? preparation.selections
        return TransactionBatchReview(
            id: preparation.id.uuidString,
            context: preparation.context,
            intent: preparation.intent,
            selections: selections,
            dispositions: selections.map {
                .eligible(TransactionBatchEffectSummary(
                    selection: $0,
                    affectedTransactionIDs: [$0.transactionID],
                    description: "One row would be changed."
                ))
            },
            rowChanges: selections.map {
                let snapshot = makeRowSnapshot(id: $0.transactionID, cleared: false)
                return TransactionBatchRowChange(before: snapshot, after: snapshot)
            },
            metadata: reviewMetadata,
            clearTarget: preparation.intent == .clear ? true : nil,
            reviewFingerprint: "fingerprint",
            effectsDescription: "One physical row is affected.",
            authorization: nil,
            canSubmit: true
        )
    }

    private func makeRowSnapshot(id: String, cleared: Bool?, parentID: String? = nil) -> TransactionBatchRowSnapshot {
        TransactionBatchRowSnapshot(
            id: id,
            accountID: "account",
            dateValue: 20260901,
            amount: -100,
            payeeID: nil,
            categoryID: nil,
            notes: nil,
            cleared: cleared,
            reconciled: false,
            tombstone: false,
            isParent: false,
            isChild: parentID != nil,
            parentID: parentID,
            transferID: nil,
            sortOrder: nil,
            startingBalance: false,
            splitError: nil,
            scheduleID: nil,
            importedID: nil,
            importedPayee: nil
        )
    }

    private var reviewMetadata: TransactionBatchReviewMetadata {
        TransactionBatchReviewMetadata(
            currency: .usd,
            accountNames: ["account": "Checking"],
            payeeNames: [:],
            categoryNames: [:]
        )
    }
}
