import GRDB
import Testing
@testable import Actualist

@MainActor
struct TransactionBatchUndoConflictTests {
    private let support = LocalFirstActualStoreTests()

    @Test(arguments: ["categorize", "delete"])
    func incomingTransferAddedAfterCommitBlocksUndoWithoutPersistence(_ operation: String) async throws {
        let bundle = try await support.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: "ALTER TABLE transactions ADD COLUMN reconciled INTEGER;"
        )
        let database = try #require(bundle.store.database)
        let intent: TransactionBatchIntent = operation == "delete"
            ? .delete
            : .categorize(categoryID: "utilities")
        let selection = try #require(TransactionSelectionIdentity(
            transactionID: "txn",
            familyRootID: "txn",
            role: .root
        ))
        let review = try await database.reviewTransactionBatch(
            context: TransactionSelectionContext(
                budgetID: "group-1",
                sessionGeneration: bundle.store.budgetSessionGeneration,
                scope: .spending,
                querySignature: TransactionFeedQuery().signature
            ),
            intent: intent,
            selections: [selection]
        )
        _ = try await database.commitTransactionBatch(review: review, authorization: review.authorization)
        let record = try #require(try await database.actionLogRecord(id: review.id))

        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                          description, cleared, reconciled, transferred_id, isChild)
                    VALUES ('incoming-after-commit', 'credit', 20260703, 12345, 'groceries', 0, NULL, 0,
                            'xfer-checking', 0, 0, 'txn', 0)
                """)
        }
        let afterIncomingWrite = try await persistenceState(bundle, database: database)

        let preview = try await database.actionUndoPreview(record: record)
        #expect(preview.block == .batchChanged)
        await #expect(throws: LocalFirstError.self) {
            try await database.commitActionUndo(record: record)
        }
        #expect(try await persistenceState(bundle, database: database) == afterIncomingWrite)
        #expect(try await database.actionLogRecord(id: review.id)?.status == .applied)
    }

    private func persistenceState(
        _ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle,
        database: BudgetDatabase
    ) async throws -> UndoConflictPersistenceState {
        let clock = await database.localClock
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        let queue = try DatabaseQueue(path: url.path)
        return try await queue.read { db in
            UndoConflictPersistenceState(
                transactions: try String.fetchAll(db, sql: """
                    SELECT id || '|' || COALESCE(category, '') || '|' || COALESCE(transferred_id, '') || '|'
                           || COALESCE(tombstone, 0)
                    FROM transactions ORDER BY id
                    """),
                crdtMessages: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0,
                outboxMessages: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actualist_outbox") ?? 0,
                historyRows: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actualist_action_log") ?? 0,
                clock: clock
            )
        }
    }
}

private struct UndoConflictPersistenceState: Equatable {
    let transactions: [String]
    let crdtMessages: Int
    let outboxMessages: Int
    let historyRows: Int
    let clock: HybridLogicalClock?
}
