import Foundation
import GRDB
import Testing
@testable import Actualist

/// Undo of a delete, batch or merge restores rows into an account and category.
/// If either was deleted since, the undo is refused with a typed block instead of
/// resurrecting rows inside a deleted container (main-to-dev audit F-6, item 4.4).
@Suite @MainActor struct ActionUndoReferencedRowTests {
    private typealias Refs = BudgetActionUndo.RestoredReferences
    private let support = LocalFirstActualStoreTests()

    // MARK: Pure evaluation

    @Test func deleteUndoBlocksWhenEitherTransferLegAccountIsGone() {
        let record = deleteRecord(ids: ["leg-a", "leg-b"], graph: .transfer(pairedID: "leg-b"))
        let live: [String: TransactionUndoSnapshot?] = [
            "leg-a": snapshot("leg-a", account: "checking", category: nil),
            "leg-b": snapshot("leg-b", account: "savings", category: nil)
        ]

        let missingSavings = BudgetActionUndo.evaluate(
            record: record, liveBudgeted: [:], liveTransactions: live,
            liveReferences: Refs(accountIDs: ["checking"], categoryIDs: [])
        )
        #expect(missingSavings == .blocked(.referencedRowMissing))

        let bothLive = BudgetActionUndo.evaluate(
            record: record, liveBudgeted: [:], liveTransactions: live,
            liveReferences: Refs(accountIDs: ["checking", "savings"], categoryIDs: [])
        )
        #expect(bothLive == .clean(.unTombstoneTransactions(transactionIDs: ["leg-a", "leg-b"])))
    }

    @Test func deleteUndoChecksSplitChildCategoriesButNotNilCategories() {
        let record = deleteRecord(ids: ["parent", "child"], graph: .split(childIDs: ["child"]))
        let live: [String: TransactionUndoSnapshot?] = [
            "parent": snapshot("parent", account: "checking", category: nil),
            "child": snapshot("child", account: "checking", category: "dining")
        ]

        let missingCategory = BudgetActionUndo.evaluate(
            record: record, liveBudgeted: [:], liveTransactions: live,
            liveReferences: Refs(accountIDs: ["checking"], categoryIDs: [])
        )
        #expect(missingCategory == .blocked(.referencedRowMissing))

        let present = BudgetActionUndo.evaluate(
            record: record, liveBudgeted: [:], liveTransactions: live,
            liveReferences: Refs(accountIDs: ["checking"], categoryIDs: ["dining"])
        )
        #expect(present == .clean(.unTombstoneTransactions(transactionIDs: ["parent", "child"])))
    }

    @Test func batchRestoreBlocksWhenABeforeSnapshotCategoryIsGone() {
        let before = batchSnapshot(category: "groceries")
        let after = batchSnapshot(category: "dining")
        let inverse = TransactionBatchTransactionInverse(
            operation: .categorize, selectedTransactionIDs: ["txn-1"],
            beforeSnapshots: [before], afterSnapshots: [after], learning: .empty
        )
        let record = makeRecord(
            inverse: .transactionBatch(inverse),
            summary: .transactionBatch(TransactionBatchBudgetAction(
                operation: .categorize, selectedCount: 1, changedCount: 1, clearTarget: nil, categoryID: "dining"
            ))
        )

        let blocked = BudgetActionUndo.evaluate(
            record: record, liveBudgeted: [:], liveTransactionBatchSnapshots: ["txn-1": after],
            liveReferences: Refs(accountIDs: ["checking"], categoryIDs: ["dining"])
        )
        #expect(blocked == .blocked(.referencedRowMissing))

        let clean = BudgetActionUndo.evaluate(
            record: record, liveBudgeted: [:], liveTransactionBatchSnapshots: ["txn-1": after],
            liveReferences: Refs(accountIDs: ["checking"], categoryIDs: ["groceries"])
        )
        #expect(clean == .clean(.restoreBatchTransactions(snapshots: [before], learning: .empty)))
    }

    @Test func mergeRestoreReferencesComeFromTheBeforeSnapshots() {
        let inverse = BudgetActionInverse.transactionMerge(TransactionMergeTransactionInverse(
            beforeSnapshots: [batchSnapshot(category: "groceries")],
            afterSnapshots: [batchSnapshot(category: "dining")]
        ))

        let references = BudgetActionUndo.restoredReferences(inverse: inverse, liveTransactions: [:])

        #expect(references == Refs(accountIDs: ["checking"], categoryIDs: ["groceries"]))
    }

    @Test func blockCopyNamesTheDeletedRow() {
        let reason = BudgetActionUndoBlock.referencedRowMissing.userFacingReason
        #expect(reason.contains("account or category"))
    }

    // MARK: Database undo

    @Test func undoOfADeleteIsBlockedWhenItsCategoryWasDeleted() async throws {
        let fixture = try await deletedTransactionFixture()
        try await fixture.execute("UPDATE categories SET tombstone = 1 WHERE id = 'groceries'")

        try await expectBlocked(fixture)
    }

    @Test func undoOfADeleteIsBlockedWhenItsAccountWasDeleted() async throws {
        let fixture = try await deletedTransactionFixture()
        try await fixture.execute("UPDATE accounts SET tombstone = 1 WHERE id = 'checking'")

        try await expectBlocked(fixture)
    }

    @Test func undoOfADeleteIsAllowedWhenItsAccountIsOnlyClosed() async throws {
        let fixture = try await deletedTransactionFixture()
        try await fixture.execute("UPDATE accounts SET closed = 1 WHERE id = 'checking'")

        try await fixture.store.undoBudgetActionAndRefresh(actionID: fixture.actionID, budgetID: "group-1")

        let rows = try await fixture.store.recentBudgetActions(budgetID: "group-1")
        #expect(rows.first { $0.id == fixture.actionID }?.status == .undone)
    }

    private struct DeletedTransactionFixture {
        let store: LocalFirstActualStore
        let databaseURL: URL
        let actionID: String

        func execute(_ sql: String) async throws {
            try await DatabaseQueue(path: databaseURL.path).write { db in try db.execute(sql: sql) }
        }
    }

    private func deletedTransactionFixture() async throws -> DeletedTransactionFixture {
        let bundle = try await support.makeOpenedWritableStoreBundle()
        let store = bundle.store
        let draft = TransactionDraft(
            accountID: "checking", date: try support.makeDate(year: 2026, month: 7, day: 11),
            amountMinorUnits: -725, payeeID: "coffee", payeeName: "Coffee Shop",
            categoryID: "groceries", notes: nil, cleared: false, isTransfer: false
        )
        let created = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        let transactionID = try #require(created.changed.transactions.first)
        let row = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == transactionID }
        )
        _ = try await store.deleteTransactionAndRefresh(row, budgetID: "group-1") {}
        let actions = try await store.recentBudgetActions(budgetID: "group-1")
        let deleteAction = try #require(actions.first)
        #expect(deleteAction.kind == .deleteTransaction)
        return DeletedTransactionFixture(
            store: store,
            databaseURL: try bundle.fileManager.databaseURL(fileID: "file-1"),
            actionID: deleteAction.id
        )
    }

    private func expectBlocked(_ fixture: DeletedTransactionFixture) async throws {
        let preview = try await fixture.store.budgetActionUndoPreview(
            actionID: fixture.actionID, budgetID: "group-1"
        )
        #expect(preview.block == .referencedRowMissing)

        await #expect(throws: LocalFirstError.actionUndoBlocked(
            BudgetActionUndoBlock.referencedRowMissing.userFacingReason
        )) {
            try await fixture.store.undoBudgetActionAndRefresh(actionID: fixture.actionID, budgetID: "group-1")
        }
        let rows = try await fixture.store.recentBudgetActions(budgetID: "group-1")
        #expect(rows.first { $0.id == fixture.actionID }?.status == .applied)
    }

    // MARK: Builders

    private func makeRecord(inverse: BudgetActionInverse, summary: BudgetActionSummary) -> BudgetActionRecord {
        BudgetActionRecord(
            id: "action-1", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .deleteTransaction, status: .applied, month: "2026-07",
            summary: summary, inverse: inverse, affectedCategoryIDs: [],
            forwardTimestampStart: nil, forwardTimestampEnd: nil, source: .ui
        )
    }

    private func deleteRecord(ids: [String], graph: BudgetTransactionGraph) -> BudgetActionRecord {
        makeRecord(
            inverse: .deleteTransaction(DeleteTransactionInverse(month: "2026-07", transactionIDs: ids, graph: graph)),
            summary: .deleteTransaction(TransactionBudgetAction(
                month: "2026-07", amount: -725, payeeName: nil, categoryID: nil, graph: .simple, transactionCount: ids.count
            ))
        )
    }

    private func snapshot(_ id: String, account: String, category: String?) -> TransactionUndoSnapshot {
        TransactionUndoSnapshot(
            id: id, accountID: account, dateValue: 20260711, amount: -725, payeeID: nil,
            categoryID: category, notes: nil, cleared: false, tombstone: true, transferID: nil,
            isParent: false, isChild: false, parentID: nil
        )
    }

    private func batchSnapshot(category: String?) -> TransactionBatchTransactionSnapshot {
        TransactionBatchTransactionSnapshot(
            id: "txn-1",
            columns: ["acct", "amount", "category", "date", "description", "tombstone"],
            accountID: "checking", dateValue: 20260901, amount: -100, payeeID: nil,
            categoryID: category, notes: nil, cleared: false, reconciled: false, tombstone: false,
            isParent: false, isChild: false, parentID: nil, transferID: nil, sortOrder: nil,
            splitError: nil, startingBalance: false, scheduleID: nil, importedID: nil,
            importedPayee: nil, importedDescription: nil
        )
    }
}
