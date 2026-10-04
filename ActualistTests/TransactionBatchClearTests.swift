import Foundation
import GRDB
import Testing
@testable import Actualist

/// Batch Clear inside split families. Actual's `makeChild` copies the parent's
/// `cleared` onto every child, so a family never holds a child that diverges
/// from its parent through this action
/// (`packages/loot-core/src/shared/transactions.ts`, `updateTransaction`).
@MainActor
struct TransactionBatchClearTests {
    private let base = TransactionBatchMutationTests()
    private let rows = TransactionBatchDeleteTests()

    private typealias Fixture = TransactionBatchDeleteTests

    private func clearedStates(
        _ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle
    ) throws -> [String: Int] {
        try base.readRows(bundle) { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, cleared FROM transactions")
                .map { ($0["id"] as String, $0["cleared"] as Int? ?? 0) })
        }
    }

    private func review(
        _ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle,
        _ selections: [TransactionSelectionIdentity]
    ) async throws -> TransactionBatchReview {
        try await bundle.store.reviewTransactionBatch(
            context: base.context(for: bundle.store), intent: .clear, selections: selections
        )
    }

    @Test func clearingASplitParentClearsEveryChild() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL: Fixture.family(children: 2))
        let review = try await review(bundle, [base.identity("p")])
        #expect(review.clearTarget == true)
        _ = try await bundle.store.commitTransactionBatch(review: review, authorization: nil)
        let state = try clearedStates(bundle)
        #expect(state["p"] == 1)
        #expect(state["c1"] == 1, "children must follow the parent's cleared state")
        #expect(state["c2"] == 1)
    }

    @Test func unclearingAClearedSplitParentUnclearsMixedChildren() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL:
            Fixture.row("p", amount: -600, isParent: true, category: nil, cleared: true)
            + Fixture.row("c1", amount: -300, parent: "p", cleared: true)
            + Fixture.row("c2", amount: -300, parent: "p", cleared: true))
        let review = try await review(bundle, [base.identity("p")])
        #expect(review.clearTarget == false)
        _ = try await bundle.store.commitTransactionBatch(review: review, authorization: nil)
        let state = try clearedStates(bundle)
        #expect(state["p"] == 0)
        #expect(state["c1"] == 0)
        #expect(state["c2"] == 0)
    }

    @Test func mixedChildrenFollowTheParentAndUndoRestoresEachRow() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL:
            Fixture.row("p", amount: -600, isParent: true, category: nil)
            + Fixture.row("c1", amount: -300, parent: "p", cleared: true)
            + Fixture.row("c2", amount: -300, parent: "p"))
        let before = try clearedStates(bundle)
        let review = try await review(bundle, [base.identity("p")])
        _ = try await bundle.store.commitTransactionBatch(review: review, authorization: nil)
        let state = try clearedStates(bundle)
        #expect(state["c1"] == 1)
        #expect(state["c2"] == 1, "an uncleared child must follow its parent")
        let database = try bundle.store.requireDatabase(for: "group-1")
        let record = try #require(try await database.actionLogRecord(id: review.id))
        _ = try await database.commitActionUndo(record: record)
        #expect(try clearedStates(bundle) == before)
    }

    @Test func clearingAChildAloneDoesNotDivergeFromItsParentAndIsANoOpReview() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL: Fixture.family(children: 2))
        let review = try await review(bundle, [rows.child("c1")])
        #expect(!review.canSubmit, "a child-only Clear that matches its parent has nothing to write")
        #expect(review.blockedCount == 0)
        #expect(review.actionableCount == 1)
        #expect(try clearedStates(bundle)["c1"] == 0)
        await #expect(throws: LocalFirstError.self) {
            try await bundle.store.commitTransactionBatch(review: review, authorization: nil)
        }
        #expect(try clearedStates(bundle)["c1"] == 0)
    }

    @Test func clearingAChildWhoseParentIsClearedConvergesOnTheParent() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL:
            Fixture.row("p", amount: -600, isParent: true, category: nil, cleared: true)
            + Fixture.row("c1", amount: -300, parent: "p")
            + Fixture.row("c2", amount: -300, parent: "p", cleared: true))
        let review = try await review(bundle, [rows.child("c1")])
        #expect(review.canSubmit)
        _ = try await bundle.store.commitTransactionBatch(review: review, authorization: nil)
        let state = try clearedStates(bundle)
        #expect(state["c1"] == 1)
        #expect(state["p"] == 1)
        #expect(state["c2"] == 1)
    }

    @Test func parentAndChildSelectedTogetherWriteEachRowOnce() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL: Fixture.family(children: 2))
        let review = try await review(bundle, [rows.child("c1"), base.identity("p")])
        let outcome = try await bundle.store.commitTransactionBatch(review: review, authorization: nil)
        #expect(Set(outcome.receipt.changedTransactionIDs) == ["p", "c1", "c2"])
        #expect(try clearedStates(bundle) == ["p": 1, "c1": 1, "c2": 1, "txn": 0])
    }

    @Test func reconciledChildKeepsItsClearedStateWhenTheParentChanges() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL:
            Fixture.row("p", amount: -600, isParent: true, category: nil)
            + Fixture.row("c1", amount: -300, parent: "p", cleared: false, reconciled: true)
            + Fixture.row("c2", amount: -300, parent: "p"))
        let review = try await review(bundle, [base.identity("p")])
        _ = try await bundle.store.commitTransactionBatch(review: review, authorization: nil)
        let state = try clearedStates(bundle)
        #expect(state["p"] == 1)
        #expect(state["c2"] == 1)
        #expect(state["c1"] == 0)
    }

    @Test func reconciledParentIsSkippedAndItsFamilyIsLeftUnchanged() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL:
            Fixture.row("p", amount: -600, isParent: true, category: nil, reconciled: true)
            + Fixture.row("c1", amount: -300, parent: "p", reconciled: true)
            + Fixture.row("c2", amount: -300, parent: "p", reconciled: true))
        let review = try await review(bundle, [base.identity("p")])
        #expect(review.skippedCount == 1)
        #expect(!review.canSubmit)
    }

    @Test func clearDirectionComesFromTheSelectionNotFromOtherLoadedRows() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL:
            "UPDATE transactions SET cleared = 1 WHERE id = 'txn';"
            + Fixture.row("other", amount: -100))
        let review = try await bundle.store.reviewTransactionBatch(
            context: base.context(for: bundle.store), intent: .clear, selections: [base.identity("txn")]
        )
        #expect(review.clearTarget == false, "an unselected uncleared feed row must not decide the direction")
        #expect(review.canSubmit)
        _ = try await bundle.store.commitTransactionBatch(review: review, authorization: nil)
        let state = try clearedStates(bundle)
        #expect(state["txn"] == 0)
        #expect(state["other"] == 0)
    }

    @Test func unclearedTransferPairDoesNotDecideTheClearDirection() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL:
            Fixture.row("leg-a", amount: -500, transfer: "leg-b", cleared: true)
            + Fixture.row("leg-b", account: "credit", amount: 500, transfer: "leg-a"))
        let review = try await bundle.store.reviewTransactionBatch(
            context: base.context(for: bundle.store), intent: .clear, selections: [base.identity("leg-a")]
        )
        #expect(review.clearTarget == false)
        _ = try await bundle.store.commitTransactionBatch(review: review, authorization: nil)
        let state = try clearedStates(bundle)
        #expect(state["leg-a"] == 0)
        #expect(state["leg-b"] == 0)
    }

    @Test func clearDirectionUsesTheWholeSelectedFamilyButNotOtherFamilies() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL:
            Fixture.row("p", amount: -600, isParent: true, category: nil, cleared: true)
            + Fixture.row("c1", amount: -300, parent: "p", cleared: true)
            + Fixture.row("c2", amount: -300, parent: "p", cleared: true)
            + Fixture.row("other", amount: -100))
        let review = try await bundle.store.reviewTransactionBatch(
            context: base.context(for: bundle.store), intent: .clear, selections: [rows.child("c1")]
        )
        #expect(review.clearTarget == false)
    }
}
