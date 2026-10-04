import Foundation
import GRDB
import Testing
@testable import Actualist

/// Batch delete over split families and transfer legs. Reuses the fixtures of
/// `TransactionBatchMutationTests` and its Actual-parity expectations
/// (`deleteTransaction` in `packages/loot-core/src/shared/transactions.ts`).
@MainActor
struct TransactionBatchDeleteTests {
    private let base = TransactionBatchMutationTests()

    static func row(
        _ id: String, account: String = "checking", amount: Int, parent: String? = nil,
        isParent: Bool = false, transfer: String? = nil, category: String? = "groceries",
        cleared: Bool = false, reconciled: Bool = false
    ) -> String {
        """
        INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                  description, cleared, reconciled, transferred_id, isChild)
            VALUES ('\(id)', '\(account)', 20260705, \(amount), \(category.map { "'\($0)'" } ?? "NULL"), 0,
                    \(parent.map { "'\($0)'" } ?? "NULL"), \(isParent ? 1 : 0), 'coffee', \(cleared ? 1 : 0), \(reconciled ? 1 : 0),
                    \(transfer.map { "'\($0)'" } ?? "NULL"), \(parent == nil ? 0 : 1));

        """
    }

    /// Parent `p` (-900, no category) with children `c1...cN` of -300 each.
    static func family(children: Int, transferOn child: String? = nil, to leg: String? = nil) -> String {
        var sql = row("p", amount: -300 * children, isParent: true, category: nil)
        for index in 1...children {
            let id = "c\(index)"
            sql += row(id, amount: -300, parent: "p", transfer: id == child ? leg : nil)
        }
        return sql
    }

    func child(_ id: String) -> TransactionSelectionIdentity {
        TransactionSelectionIdentity(transactionID: id, familyRootID: "p", role: .child)!
    }

    private func tombstones(
        _ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle
    ) throws -> [String: Int] {
        try base.readRows(bundle) { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, tombstone FROM transactions")
                .map { ($0["id"] as String, $0["tombstone"] as Int? ?? 0) })
        }
    }

    private func fullState(
        _ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle
    ) throws -> [String] {
        try base.readRows(bundle) { db in
            try String.fetchAll(db, sql: """
                SELECT id || '|' || tombstone || '|' || is_parent || '|' || amount || '|'
                       || COALESCE(category, '') || '|' || COALESCE(transferred_id, '') || '|'
                       || COALESCE(description, '') || '|' || COALESCE(error, '')
                FROM transactions ORDER BY id
                """)
        }
    }

    private func commitDelete(
        _ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle,
        _ selections: [TransactionSelectionIdentity]
    ) async throws -> TransactionBatchReview {
        let review = try await bundle.store.reviewTransactionBatch(
            context: base.context(for: bundle.store), intent: .delete, selections: selections,
            loadedUngroupedTransactionIDs: selections.map(\.transactionID)
        )
        #expect(review.canSubmit)
        _ = try await bundle.store.commitTransactionBatch(review: review, authorization: nil)
        return review
    }

    @Test func deletingTwoOfThreeChildrenKeepsTheThirdChildAndParent() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL: Self.family(children: 3))
        let review = try await commitDelete(bundle, [child("c1"), child("c2")])
        let state = try tombstones(bundle)
        #expect(state["c1"] == 1)
        #expect(state["c2"] == 1, "second selected child must not be skipped")
        #expect(state["c3"] == 0)
        #expect(state["p"] == 0)
        #expect(review.effectsDescription == "Delete 2 transaction rows.")
    }

    @Test func deletingEveryChildMakesTheParentAPlainTransaction() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL: Self.family(children: 2))
        let review = try await commitDelete(bundle, [child("c1"), child("c2")])
        let state = try tombstones(bundle)
        #expect(state["c1"] == 1)
        #expect(state["c2"] == 1)
        #expect(state["p"] == 0)
        // Upstream deleteTransaction: the last child's removal clears is_parent
        // and error and leaves the parent's amount and category untouched.
        let parent = try base.readRows(bundle) { db in
            try Row.fetchOne(db, sql: "SELECT is_parent, amount, category, error FROM transactions WHERE id = 'p'")
        }
        #expect(parent?["is_parent"] as Int? == 0)
        #expect(parent?["amount"] as Int? == -600)
        #expect(parent?["category"] as String? == nil)
        #expect(parent?["error"] as String? == nil)
        #expect(review.effectsDescription == "Delete 2 transaction rows.")
    }

    @Test(arguments: [true, false])
    func selectingAChildAndItsParentDeletesTheWholeFamily(childFirst: Bool) async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL: Self.family(children: 3))
        let parent = base.identity("p")
        let review = try await commitDelete(bundle, childFirst ? [child("c1"), parent] : [parent, child("c1")])
        let state = try tombstones(bundle)
        #expect(state["p"] == 1, "selected parent must not be skipped")
        #expect(["c1", "c2", "c3"].allSatisfy { state[$0] == 1 })
        #expect(review.effectsDescription.hasPrefix("Delete 4 transaction rows."))
    }

    @Test(arguments: [true, false])
    func transferLegWhoseCounterpartIsASplitChildDeletesBothSelectedRows(legFirst: Bool) async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL:
            Self.family(children: 3, transferOn: "c3", to: "leg")
            + Self.row("leg", account: "credit", amount: 300, transfer: "c3"))
        let selections = legFirst ? [base.identity("leg"), child("c3")] : [child("c3"), base.identity("leg")]
        let review = try await commitDelete(bundle, selections)
        let state = try tombstones(bundle)
        #expect(state["leg"] == 1)
        #expect(state["c3"] == 1, "selected split child must not be skipped")
        #expect(state["c1"] == 0)
        #expect(state["c2"] == 0)
        #expect(state["p"] == 0)
        #expect(review.effectsDescription.hasPrefix("Delete 2 transaction rows."))
    }

    @Test func unselectedSplitChildKeepsItsFamilyWhenOnlyItsTransferLegIsDeleted() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL:
            Self.family(children: 2, transferOn: "c2", to: "leg")
            + Self.row("leg", account: "credit", amount: 300, transfer: "c2"))
        _ = try await commitDelete(bundle, [base.identity("leg")])
        let state = try tombstones(bundle)
        #expect(state["leg"] == 1)
        #expect(state["c2"] == 0)
        let link = try base.readRows(bundle) { db in
            try String.fetchOne(db, sql: "SELECT transferred_id FROM transactions WHERE id = 'c2'")
        }
        #expect(link == nil)
    }

    /// Characterization: this already behaved correctly before the overlay.
    @Test func deletingBothPlainTransferLegsTombstonesExactlyTwoRows() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL:
            Self.row("leg-a", amount: -500, transfer: "leg-b")
            + Self.row("leg-b", account: "credit", amount: 500, transfer: "leg-a"))
        let review = try await commitDelete(bundle, [base.identity("leg-a"), base.identity("leg-b")])
        let state = try tombstones(bundle)
        #expect(state["leg-a"] == 1)
        #expect(state["leg-b"] == 1)
        #expect(state["txn"] == 0)
        #expect(review.effectsDescription == "Delete 2 transaction rows.")
    }

    @Test func undoAfterPartialChildDeleteRestoresEveryRow() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL: Self.family(children: 3))
        let before = try fullState(bundle)
        let review = try await commitDelete(bundle, [child("c1"), child("c2")])
        #expect(try fullState(bundle) != before)
        let database = try bundle.store.requireDatabase(for: "group-1")
        let record = try #require(try await database.actionLogRecord(id: review.id))
        guard case .transactionBatch(let summary) = record.summary else {
            Issue.record("Expected a batch summary")
            return
        }
        #expect(summary.changedCount == 2)
        let preview = try await database.actionUndoPreview(record: record)
        #expect(preview.block == nil)
        _ = try await database.commitActionUndo(record: record)
        #expect(try fullState(bundle) == before)
    }
}
