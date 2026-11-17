import Foundation
import GRDB
import Testing
@testable import Actualist

/// Deleting a transfer leg clears its link (loot-core `transfer.onDelete`), and History undo writes back only
/// the cells its action changed (Actual's `undoWrites`), so a cell edited on another device is never overwritten.
@MainActor
struct TransactionUndoChangedCellsTests {
    private let batch = TransactionBatchMutationTests()
    private let support = LocalFirstActualStoreTests()

    private func cells(since before: [ActualSyncDecodedMessage], in bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle) throws -> Set<String> {
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        let known = Set(before.map(\.timestamp))
        return Set(try support.storedCRDTMessages(at: url).filter { !known.contains($0.timestamp) }.map { "\($0.row).\($0.column)" })
    }

    private func messages(in bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle) throws -> [ActualSyncDecodedMessage] {
        try support.storedCRDTMessages(at: try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID)))
    }

    private func link(_ id: String, in bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle) throws -> String? {
        try batch.readRows(bundle) { db in
            try String.fetchOne(db, sql: "SELECT transferred_id FROM transactions WHERE id = ?", arguments: [id])
        }
    }

    private func latestRecord(in bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle) async throws -> BudgetActionRecord {
        let id = try batch.readRows(bundle) { db in
            try String.fetchOne(db, sql: "SELECT id FROM actualist_action_log ORDER BY rowid DESC LIMIT 1")
        }
        let logID = try #require(id)
        return try #require(try await ActionLogStorageSQL.actionLogRecord(id: logID, in: bundle.store.requireDatabase(for: "group-1")))
    }

    private static let legs = TransactionBatchDeleteTests.row("leg-a", amount: -500, transfer: "leg-b")
        + TransactionBatchDeleteTests.row("leg-b", account: "credit", amount: 500, transfer: "leg-a")

    @Test func singleDeleteOfATransferLegClearsItsLinkAndUndoRestoresIt() async throws {
        let bundle = try await batch.makeBatchFixture(additionalFixtureSQL: Self.legs)
        let store = bundle.store
        let leg = try #require(try await store.fetchTransaction(budgetID: "group-1", id: "leg-a"))
        let beforeDelete = try messages(in: bundle)

        _ = try await store.deleteTransactionAndRefresh(leg, budgetID: "group-1", didDelete: {})

        #expect(try cells(since: beforeDelete, in: bundle) == ["leg-a.tombstone", "leg-a.transferred_id", "leg-b.tombstone"])
        #expect(try link("leg-a", in: bundle) == nil)
        #expect(try link("leg-b", in: bundle) == "leg-a")

        let record = try await latestRecord(in: bundle)
        let beforeUndo = try messages(in: bundle)
        _ = try await store.requireDatabase(for: "group-1").commitActionUndo(record: record)

        #expect(try cells(since: beforeUndo, in: bundle) == ["leg-a.tombstone", "leg-a.transferred_id", "leg-b.tombstone"])
        #expect(try link("leg-a", in: bundle) == "leg-b")
    }

    @Test func batchDeleteOfATransferLegClearsItsLinkAndUndoWritesOnlyChangedCells() async throws {
        let bundle = try await batch.makeBatchFixture(additionalFixtureSQL: Self.legs)
        let store = bundle.store
        let beforeDelete = try messages(in: bundle)
        let review = try await store.reviewTransactionBatch(
            context: batch.context(for: store), intent: .delete, selections: [batch.identity("leg-a")]
        )
        _ = try await store.commitTransactionBatch(review: review, authorization: nil)

        #expect(try cells(since: beforeDelete, in: bundle) == ["leg-a.tombstone", "leg-a.transferred_id", "leg-b.tombstone"])
        #expect(try link("leg-a", in: bundle) == nil)

        let record = try #require(try await ActionLogStorageSQL.actionLogRecord(id: review.id, in: store.requireDatabase(for: "group-1")))
        let beforeUndo = try messages(in: bundle)
        _ = try await store.requireDatabase(for: "group-1").commitActionUndo(record: record)

        #expect(try cells(since: beforeUndo, in: bundle) == ["leg-a.tombstone", "leg-a.transferred_id", "leg-b.tombstone"])
        #expect(try link("leg-a", in: bundle) == "leg-b")
    }

    @Test func batchCategorizeUndoWritesOnlyTheCategory() async throws {
        let bundle = try await batch.makeBatchFixture()
        let store = bundle.store
        let review = try await store.reviewTransactionBatch(
            context: batch.context(for: store), intent: .categorize(categoryID: "utilities"), selections: [batch.identity("txn")]
        )
        _ = try await store.commitTransactionBatch(review: review, authorization: nil)
        let record = try #require(try await ActionLogStorageSQL.actionLogRecord(id: review.id, in: store.requireDatabase(for: "group-1")))
        let beforeUndo = try messages(in: bundle)

        _ = try await store.requireDatabase(for: "group-1").commitActionUndo(record: record)

        #expect(try cells(since: beforeUndo, in: bundle) == ["txn.category"])
    }

    @Test func editUndoWritesOnlyTheEditedCells() async throws {
        let bundle = try await batch.makeBatchFixture()
        let store = bundle.store
        let baseline = try #require(try await store.fetchTransaction(budgetID: "group-1", id: "txn"))
        let draft = TransactionDraft(
            accountID: baseline.account, date: try support.makeDate(year: 2026, month: 7, day: 3),
            amountMinorUnits: -20_000, payeeID: baseline.payee, payeeName: "", categoryID: baseline.category,
            notes: baseline.notes, cleared: baseline.cleared?.boolValue ?? false, isTransfer: false
        )
        _ = try await store.updateTransactionAndRefresh(
            "txn", with: draft, budgetID: "group-1", originalAccountID: baseline.account, originalMonth: "2026-07",
            baseline: baseline, actionSource: .ui, didUpdate: {}
        )
        let record = try await latestRecord(in: bundle)
        let beforeUndo = try messages(in: bundle)

        _ = try await store.requireDatabase(for: "group-1").commitActionUndo(record: record)

        #expect(try cells(since: beforeUndo, in: bundle) == ["txn.amount"])
    }

    @Test func editingATransactionWithNullNotesAndAnEmptyFieldWritesNoNotesCell() async throws {
        let bundle = try await batch.makeBatchFixture()
        let store = bundle.store
        let baseline = try #require(try await store.fetchTransaction(budgetID: "group-1", id: "txn"))
        #expect(baseline.notes == nil)
        let before = try messages(in: bundle)
        let draft = TransactionDraft(
            accountID: baseline.account, date: try support.makeDate(year: 2026, month: 7, day: 3),
            amountMinorUnits: -20_000, payeeID: baseline.payee, payeeName: "", categoryID: baseline.category,
            notes: "", cleared: baseline.cleared?.boolValue ?? false, isTransfer: false
        )

        _ = try await store.updateTransactionAndRefresh(
            "txn", with: draft, budgetID: "group-1", originalAccountID: baseline.account, originalMonth: "2026-07",
            baseline: baseline, actionSource: .ui, didUpdate: {}
        )

        #expect(try cells(since: before, in: bundle) == ["txn.amount"])
    }
}
