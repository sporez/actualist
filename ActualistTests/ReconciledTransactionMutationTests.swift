import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct ReconciledTransactionMutationTests {
    private let support = LocalFirstActualStoreTests()

    @Test func splitReviewIncludesTheWholeFamilyAndReconciledTransferPair() async throws {
        let bundle = try makeDatabase()
        try await bundle.queue.write { db in
            try Self.insertSplitTransferGraph(db: db, pairReconciled: true)
        }

        let loadedReview = try await bundle.database.reconciledMutationReview(
            transactionID: "split-a"
        )
        let review = try #require(loadedReview)

        #expect(review.transactionID == "split-a")
        #expect(review.targetReconciledTransactionIDs == ["split", "split-a", "split-b"])
        #expect(review.pairedReconciledTransactionIDs == ["paired"])
        #expect(review.targetRequiresUnlock)
        #expect(review.includesPairedTransfer)
    }

    @Test func updateAndDeleteFailClosedUntilTheirExactReviewIsAuthorized() async throws {
        let bundle = try makeDatabase()
        try await bundle.queue.write { db in
            try db.execute(sql: "UPDATE transactions SET reconciled = 1, cleared = 1 WHERE id = 'txn'")
        }
        let loadedReview = try await bundle.database.reconciledMutationReview(
            transactionID: "txn"
        )
        let review = try #require(loadedReview)
        var draft = TransactionDraft(
            accountID: "checking",
            date: Date(timeIntervalSince1970: 1_783_070_400),
            amountMinorUnits: -12_345,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: "Edited",
            cleared: true,
            isTransfer: false
        )
        draft.reconciled = true

        var updateBuilder = LocalFirstSyncMessageBuilder()
        await #expect(throws: ReconciledTransactionMutationError.self) {
            try await bundle.database.updateTransactionMessages(
                transactionID: "txn",
                draft: draft,
                payeeID: "coffee",
                builder: &updateBuilder
            )
        }
        let update = try await bundle.database.updateTransactionMessages(
            transactionID: "txn",
            draft: draft,
            payeeID: "coffee",
            reconciliationAuthorization: review.authorization,
            builder: &updateBuilder
        )
        #expect(update.affectedTransactionIDs == ["txn"])

        var deleteBuilder = LocalFirstSyncMessageBuilder()
        await #expect(throws: ReconciledTransactionMutationError.self) {
            try await bundle.database.deleteTransactionMessages(
                transactionID: "txn",
                builder: &deleteBuilder
            )
        }
        let delete = try await bundle.database.deleteTransactionMessages(
            transactionID: "txn",
            reconciliationAuthorization: review.authorization,
            builder: &deleteBuilder
        )
        #expect(delete.affectedTransactionIDs == ["txn"])
    }

    @Test func newlyReconciledTransferPairInvalidatesAnEarlierConfirmation() async throws {
        let bundle = try makeDatabase()
        try await bundle.queue.write { db in
            try Self.insertSplitTransferGraph(db: db, pairReconciled: false)
        }
        let loadedReview = try await bundle.database.reconciledMutationReview(
            transactionID: "split-a"
        )
        let firstReview = try #require(loadedReview)
        #expect(firstReview.pairedReconciledTransactionIDs.isEmpty)

        try await bundle.queue.write { db in
            try db.execute(sql: "UPDATE transactions SET reconciled = 1 WHERE id = 'paired'")
        }
        var builder = LocalFirstSyncMessageBuilder()
        do {
            _ = try await bundle.database.deleteTransactionMessages(
                transactionID: "split-a",
                reconciliationAuthorization: firstReview.authorization,
                builder: &builder
            )
            Issue.record("A stale confirmation changed newly reconciled data")
        } catch let error as ReconciledTransactionMutationError {
            guard case .confirmationRequired(let freshReview) = error else {
                Issue.record("Expected a fresh reconciliation review")
                return
            }
            #expect(freshReview.pairedReconciledTransactionIDs == ["paired"])
        }
    }

    @Test func newlyReconciledTransferPairStopsMessagesAtTheAtomicCommitBoundary() async throws {
        let bundle = try makeDatabase()
        try await bundle.queue.write { db in
            try Self.insertSplitTransferGraph(db: db, pairReconciled: false)
        }
        let loadedReview = try await bundle.database.reconciledMutationReview(
            transactionID: "split-a"
        )
        let firstReview = try #require(loadedReview)
        var builder = LocalFirstSyncMessageBuilder()
        let delete = try await bundle.database.deleteTransactionMessages(
            transactionID: "split-a",
            reconciliationAuthorization: firstReview.authorization,
            builder: &builder
        )

        try await bundle.queue.write { db in
            try db.execute(sql: "UPDATE transactions SET reconciled = 1 WHERE id = 'paired'")
        }
        do {
            _ = try await bundle.database.commitLocalSyncMessagesAndEnqueue(
                delete.messages,
                reconciledMutationPrecondition: ReconciledTransactionMutationPrecondition(
                    transactionID: "split-a",
                    authorization: firstReview.authorization
                )
            )
            Issue.record("A stale confirmation committed messages against newly reconciled data")
        } catch let error as ReconciledTransactionMutationError {
            guard case .confirmationRequired(let freshReview) = error else {
                Issue.record("Expected a fresh reconciliation review")
                return
            }
            #expect(freshReview.pairedReconciledTransactionIDs == ["paired"])
        }

        let state = try await bundle.queue.read { db in
            let tombstones = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transactions WHERE tombstone = 1"
            ) ?? 0
            let messages = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0
            let outbox = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'actualist_outbox'"
            ) ?? 0
            return (tombstones, messages, outbox)
        }
        #expect(state.0 == 0)
        #expect(state.1 == 0)
        #expect(state.2 == 0)
    }

    @Test func storeLegacyUpdateAndDeleteFailClosedAndAuthorizedDeleteCommits() async throws {
        let bundle = try await support.makeOpenedWritableStoreBundle()
        let queue = try DatabaseQueue(
            path: bundle.fileManager.databaseURL(fileID: "file-1").path
        )
        try await queue.write { db in
            try db.execute(sql: "UPDATE transactions SET reconciled = 1, cleared = 1 WHERE id = 'txn'")
        }
        let transaction = support.makeTransaction(
            id: "txn",
            category: "groceries"
        )
        let draft = TransactionDraft(
            accountID: "checking",
            date: try support.makeDate(year: 2026, month: 7, day: 3),
            amountMinorUnits: -12_345,
            payeeID: nil,
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: "Edited",
            cleared: true,
            isTransfer: false
        )

        await #expect(throws: ReconciledTransactionMutationError.self) {
            try await bundle.store.updateTransactionAndRefresh(
                "txn",
                with: draft,
                budgetID: "group-1",
                originalAccountID: "checking",
                originalMonth: "2026-07",
                didUpdate: {}
            )
        }

        await #expect(throws: ReconciledTransactionMutationError.self) {
            try await bundle.store.deleteTransactionAndRefresh(
                transaction,
                budgetID: "group-1",
                didDelete: {}
            )
        }
        let loadedReview = try await bundle.store.reconciledMutationReview(
            budgetID: "group-1",
            transactionID: "txn"
        )
        let review = try #require(loadedReview)
        _ = try await bundle.store.deleteTransactionAndRefresh(
            transaction,
            budgetID: "group-1",
            reconciliationAuthorization: review.authorization,
            didDelete: {}
        )

        let tombstone = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT tombstone FROM transactions WHERE id = 'txn'")
        }
        #expect(tombstone == 1)
    }

    private struct DatabaseBundle {
        let database: BudgetDatabase
        let queue: DatabaseQueue
    }

    private func makeDatabase() throws -> DatabaseBundle {
        let url = try support.makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions ADD COLUMN description TEXT;
            ALTER TABLE transactions ADD COLUMN notes TEXT;
            ALTER TABLE transactions ADD COLUMN cleared INTEGER DEFAULT 0;
            ALTER TABLE transactions ADD COLUMN isChild INTEGER DEFAULT 0;
            ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
            CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER);
            INSERT INTO payees VALUES ('coffee', 'Coffee Shop', NULL, 0);
            INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0, 2);
            """)
        return DatabaseBundle(
            database: try BudgetDatabase(databaseURL: url, localNodeID: "node1"),
            queue: try DatabaseQueue(path: url.path)
        )
    }

    private nonisolated static func insertSplitTransferGraph(
        db: Database,
        pairReconciled: Bool
    ) throws {
        try db.execute(sql: """
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                 description, notes, cleared, isChild, reconciled, transferred_id)
            VALUES
                ('split', 'checking', 20260901, 3000, NULL, 0, NULL, 1,
                 NULL, NULL, 1, 0, 1, NULL),
                ('split-a', 'checking', 20260901, 1000, 'groceries', 0, 'split', 0,
                 NULL, NULL, 1, 1, 1, 'paired'),
                ('split-b', 'checking', 20260901, 2000, 'groceries', 0, 'split', 0,
                 NULL, NULL, 1, 1, 1, NULL),
                ('paired', 'savings', 20260901, -1000, NULL, 0, NULL, 0,
                 NULL, NULL, 1, 0, ?, 'split-a')
            """, arguments: [pairReconciled])
    }
}
