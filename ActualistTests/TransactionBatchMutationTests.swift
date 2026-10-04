import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct TransactionBatchMutationTests {
    private let support = LocalFirstActualStoreTests()

    @Test func batchCategorizeCommitsOneHistoryActionAndUndoRestoresAtomically() async throws {
        let bundle = try await makeBatchFixture()
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await database.reviewTransactionBatch(
            context: context(for: bundle.store),
            intent: .categorize(categoryID: "utilities"),
            selections: [identity("txn")]
        )
        #expect(review.canSubmit)
        #expect(review.blockedCount == 0)
        let reviewedRow = try #require(review.rowChanges.first { $0.id == "txn" })
        #expect(reviewedRow.before.categoryID == "groceries")
        #expect(reviewedRow.after.categoryID == "utilities")
        #expect(review.metadata.accountNames["checking"]?.isEmpty == false)

        let result = try await database.commitTransactionBatch(review: review, authorization: nil)
        #expect(result.changedTransactionIDs == ["txn"])
        let records = try await database.recentBudgetActions()
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.kind == .transactionBatch)
        guard case .transactionBatch(let inverse) = record.inverse else {
            Issue.record("Expected one batch inverse")
            return
        }
        #expect(inverse.beforeSnapshots.first?.categoryID == "groceries")
        #expect(inverse.afterSnapshots.first?.categoryID == "utilities")

        let preview = try await database.actionUndoPreview(record: record)
        #expect(preview.block == nil)
        #expect(preview.transactionLines.count == 1)
        _ = try await database.commitActionUndo(record: record)
        #expect(try await database.actionLogRecord(id: record.id)?.status == .undone)
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") > 0)
    }

    @Test func staleBatchReviewIsRejectedWithoutAppendingAnyBatchMessagesOrHistory() async throws {
        let bundle = try await makeBatchFixture()
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await database.reviewTransactionBatch(
            context: context(for: bundle.store),
            intent: .categorize(categoryID: "utilities"),
            selections: [identity("txn")]
        )
        var builder = LocalFirstSyncMessageBuilder()
        let newerWrite = try builder.makeMessage(
            dataset: "transactions", row: "txn", column: "category", value: .string("dining")
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue([newerWrite])
        let pendingAfterNewerWrite = try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1")

        await #expect(throws: LocalFirstError.self) {
            try await database.commitTransactionBatch(review: review, authorization: nil)
        }
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == pendingAfterNewerWrite)
        #expect(try await database.recentBudgetActions().isEmpty)
    }

    @Test func clearCommitsEligibleRowsAndSkipsReconciledRowsAtomically() async throws {
        let bundle = try await makeBatchFixture(additionalFixtureSQL: """
            UPDATE transactions SET cleared = 0, reconciled = 0 WHERE id = 'txn';
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, cleared, reconciled, transferred_id, isChild)
                VALUES ('reconciled', 'checking', 20260704, -200, 'groceries', 0, NULL, 0,
                        'Coffee Shop', 0, 1, NULL, 0);
            """)
        let ctx = context(for: bundle.store)
        let rows = [identity("txn"), identity("reconciled")]
        let review = try await bundle.store.reviewTransactionBatch(
            context: ctx, intent: .clear, selections: rows
        )
        #expect(review.clearTarget == true)
        #expect(review.skippedCount == 1)

        let outcome = try await bundle.store.commitTransactionBatch(review: review, authorization: nil)
        #expect(outcome.receipt.changedTransactionIDs == ["txn"])
        #expect(!outcome.refreshPending)
        let state = try readRows(bundle) { db in
            (
                try Int.fetchOne(db, sql: "SELECT cleared FROM transactions WHERE id = 'txn'"),
                try Int.fetchOne(db, sql: "SELECT cleared FROM transactions WHERE id = 'reconciled'"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actualist_outbox"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actualist_action_log")
            )
        }
        #expect(state.0 == 1)
        #expect(state.1 == 0)
        #expect((state.2 ?? 0) > 0)
        #expect(state.3 == 1)
    }

    @Test func authorizationIncludesUnselectedReconciledTransferPair() async throws {
        let bundle = try await makeBatchFixture(additionalFixtureSQL: """
            UPDATE transactions SET transferred_id = 'paired', reconciled = 0 WHERE id = 'txn';
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, cleared, reconciled, transferred_id, isChild)
                VALUES ('paired', 'credit', 20260703, 12345, 'groceries', 0, NULL, 0,
                        'Coffee Shop', 0, 1, 'txn', 0);
            """)
        let review = try await bundle.store.reviewTransactionBatch(
            context: context(for: bundle.store), intent: .categorize(categoryID: "utilities"),
            selections: [identity("txn")]
        )
        let authorization = try #require(review.authorization)
        #expect(authorization.reconciledTransactionIDs.isEmpty)
        #expect(authorization.pairedReconciledTransactionIDs == ["paired"])
        let selectedDisposition = try #require(review.dispositions.first)
        guard case .requiresAuthorization(let requirement) = selectedDisposition else {
            Issue.record("Expected the selected transfer to require authorization")
            return
        }
        #expect(requirement.effect.affectedTransactionIDs == ["txn"])
        #expect(review.rowChanges.first { $0.id == "paired" }?.changed == false)

        let outcome = try await bundle.store.commitTransactionBatch(review: review, authorization: authorization)
        #expect(outcome.receipt.changedTransactionIDs == ["txn"])
    }

    @Test func reviewMetadataResolvesMergedPayeeAliasUsedByTransactionRow() async throws {
        let bundle = try await makeBatchFixture(additionalFixtureSQL: """
            UPDATE transactions SET description = 'coffee-alias' WHERE id = 'txn';
            INSERT INTO payee_mapping VALUES ('coffee-alias', 'coffee');
            """)

        let review = try await bundle.store.reviewTransactionBatch(
            context: context(for: bundle.store),
            intent: .categorize(categoryID: "utilities"),
            selections: [identity("txn")]
        )

        #expect(review.rowChanges.first?.before.payeeID == "coffee-alias")
        #expect(review.metadata.payeeNames["coffee-alias"] == "Coffee Shop")
    }

    @Test func incomingOnlyTransferLinkBlocksCategorizeAndDeleteWithoutPersistence() async throws {
        let bundle = try await makeBatchFixture(additionalFixtureSQL: """
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, cleared, reconciled, transferred_id, isChild)
                VALUES ('incoming', 'credit', 20260703, 12345, 'groceries', 0, NULL, 0,
                        'xfer-checking', 0, 0, 'txn', 0);
            """)
        let before = try await persistenceState(bundle)

        for intent in [TransactionBatchIntent.categorize(categoryID: "utilities"), .delete] {
            let review = try await bundle.store.reviewTransactionBatch(
                context: context(for: bundle.store),
                intent: intent,
                selections: [identity("txn")]
            )
            #expect(review.blockedCount == 1)
            #expect(!review.canSubmit)
            await #expect(throws: LocalFirstError.self) {
                try await bundle.store.commitTransactionBatch(review: review, authorization: review.authorization)
            }
            #expect(try await persistenceState(bundle) == before)
        }
    }

    @Test func incomingTransferLinkAddedAfterReviewInvalidatesWholeBatch() async throws {
        let bundle = try await makeBatchFixture()
        let review = try await bundle.store.reviewTransactionBatch(
            context: context(for: bundle.store),
            intent: .categorize(categoryID: "utilities"),
            selections: [identity("txn")]
        )
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                          description, cleared, reconciled, transferred_id, isChild)
                    VALUES ('incoming', 'credit', 20260703, 12345, 'groceries', 0, NULL, 0,
                            'xfer-checking', 0, 0, 'txn', 0)
                """)
        }
        let afterIncomingWrite = try await persistenceState(bundle)

        await #expect(throws: LocalFirstError.self) {
            try await bundle.store.commitTransactionBatch(review: review, authorization: nil)
        }
        #expect(try await persistenceState(bundle) == afterIncomingWrite)
    }

    @Test(arguments: ["rename", "tombstone"])
    func categoryMetadataChangeAfterReviewRejectsWholeBatch(_ mutation: String) async throws {
        let bundle = try await makeBatchFixture()
        let review = try await bundle.store.reviewTransactionBatch(
            context: context(for: bundle.store),
            intent: .categorize(categoryID: "utilities"),
            selections: [identity("txn")]
        )
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            switch mutation {
            case "rename":
                try db.execute(sql: "UPDATE categories SET name = 'Renamed Utilities' WHERE id = 'utilities'")
            case "tombstone":
                try db.execute(sql: "UPDATE categories SET tombstone = 1 WHERE id = 'utilities'")
            default:
                Issue.record("Unknown category mutation \(mutation)")
            }
        }
        let afterMetadataWrite = try await persistenceState(bundle)

        await #expect(throws: LocalFirstError.self) {
            try await bundle.store.commitTransactionBatch(review: review, authorization: nil)
        }
        #expect(try await persistenceState(bundle) == afterMetadataWrite)
    }

    @Test func tombstonedCategoryTargetIsRejectedDuringReviewWithoutPersistence() async throws {
        let bundle = try await makeBatchFixture(additionalFixtureSQL: """
            UPDATE categories SET tombstone = 1 WHERE id = 'utilities';
            """)
        let before = try await persistenceState(bundle)

        await #expect(throws: LocalFirstError.self) {
            try await bundle.store.reviewTransactionBatch(
                context: context(for: bundle.store),
                intent: .categorize(categoryID: "utilities"),
                selections: [identity("txn")]
            )
        }
        #expect(try await persistenceState(bundle) == before)
    }

    @Test func explicitCategoryTargetFailsClosedWhenCategoryTableIsAbsent() async throws {
        let bundle = try await makeBatchFixture()
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in try db.execute(sql: "DROP TABLE categories") }
        // Open the incomplete schema afresh instead of retaining the store's
        // already-populated table-existence cache across external fixture DDL.
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "batch-missing-category")
        let transactionBefore = try readRows(bundle) { db in
            try String.fetchOne(db, sql: "SELECT category FROM transactions WHERE id = 'txn'")
        }
        let crdtBefore = try readRows(bundle) { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0
        }
        let outboxBefore = try await database.pendingLocalSyncMessageCount()
        let historyBefore = try await database.recentBudgetActions().count
        let clockBefore = await database.localClock

        await #expect(throws: LocalFirstError.self) {
            try await database.reviewTransactionBatch(
                context: context(for: bundle.store),
                intent: .categorize(categoryID: "utilities"),
                selections: [identity("txn")]
            )
        }

        #expect(try readRows(bundle) { db in
            try String.fetchOne(db, sql: "SELECT category FROM transactions WHERE id = 'txn'")
        } == transactionBefore)
        #expect(try readRows(bundle) { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0
        } == crdtBefore)
        #expect(try await database.pendingLocalSyncMessageCount() == outboxBefore)
        #expect(try await database.recentBudgetActions().count == historyBefore)
        #expect(await database.localClock == clockBefore)
    }

    @Test(arguments: [
        "self-link", "wrong-amount", "same-account", "minimum-amount",
        "nonreciprocal", "extra-backlink",
    ])
    func malformedTransferGraphBlocksBatchWithoutWrites(_ corruption: String) async throws {
        let pairSetup: String
        switch corruption {
        case "self-link":
            pairSetup = "UPDATE transactions SET transferred_id = 'txn' WHERE id = 'txn';"
        case "wrong-amount":
            pairSetup = """
                UPDATE transactions SET transferred_id = 'paired' WHERE id = 'txn';
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                          description, cleared, reconciled, transferred_id, isChild)
                    VALUES ('paired', 'credit', 20260703, 12344, 'groceries', 0, NULL, 0,
                            'Coffee Shop', 0, 0, 'txn', 0);
                """
        case "same-account":
            pairSetup = """
                UPDATE transactions SET transferred_id = 'paired' WHERE id = 'txn';
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                          description, cleared, reconciled, transferred_id, isChild)
                    VALUES ('paired', 'checking', 20260703, 12345, 'groceries', 0, NULL, 0,
                            'Coffee Shop', 0, 0, 'txn', 0);
                """
        case "minimum-amount":
            pairSetup = """
                UPDATE transactions SET amount = (-9223372036854775807 - 1), transferred_id = 'paired' WHERE id = 'txn';
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                          description, cleared, reconciled, transferred_id, isChild)
                    VALUES ('paired', 'credit', 20260703, 0, 'groceries', 0, NULL, 0,
                            'Coffee Shop', 0, 0, 'txn', 0);
                """
        case "nonreciprocal":
            pairSetup = """
                UPDATE transactions SET transferred_id = 'paired' WHERE id = 'txn';
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                          description, cleared, reconciled, transferred_id, isChild)
                    VALUES ('paired', 'credit', 20260703, 12345, 'groceries', 0, NULL, 0,
                            'xfer-checking', 0, 0, NULL, 0);
                """
        case "extra-backlink":
            pairSetup = """
                UPDATE transactions SET transferred_id = 'paired' WHERE id = 'txn';
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                          description, cleared, reconciled, transferred_id, isChild)
                    VALUES ('paired', 'credit', 20260703, 12345, 'groceries', 0, NULL, 0,
                            'xfer-checking', 0, 0, 'txn', 0);
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                          description, cleared, reconciled, transferred_id, isChild)
                    VALUES ('extra', 'savings', 20260703, 1, 'groceries', 0, NULL, 0,
                            'xfer-checking', 0, 0, 'txn', 0);
                """
        default:
            Issue.record("Unknown malformed-transfer fixture: \(corruption)")
            return
        }
        let bundle = try await makeBatchFixture(additionalFixtureSQL: pairSetup)
        let database = try bundle.store.requireDatabase(for: "group-1")
        let rowsBefore = try readRows(bundle) { db in
            try String.fetchAll(db, sql: """
                SELECT id || '|' || acct || '|' || amount || '|' || COALESCE(category, '') || '|'
                       || COALESCE(transferred_id, '')
                FROM transactions ORDER BY id
                """)
        }
        let outboxBefore = try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1")
        let clockBefore = await database.localClock
        let review = try await bundle.store.reviewTransactionBatch(
            context: context(for: bundle.store), intent: .categorize(categoryID: "utilities"),
            selections: [identity("txn")]
        )
        #expect(review.blockedCount == 1)
        #expect(!review.canSubmit)

        do {
            _ = try await bundle.store.commitTransactionBatch(review: review, authorization: review.authorization)
            Issue.record("Expected malformed transfer graph \(corruption) to block commit")
        } catch is LocalFirstError { }

        #expect(try readRows(bundle) { db in
            try String.fetchAll(db, sql: """
                SELECT id || '|' || acct || '|' || amount || '|' || COALESCE(category, '') || '|'
                       || COALESCE(transferred_id, '')
                FROM transactions ORDER BY id
                """)
        } == rowsBefore)
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == outboxBefore)
        #expect(try await database.recentBudgetActions().isEmpty)
        #expect(await database.localClock == clockBefore)
    }

    @Test func mixedSupportedAndBlockedCategorizationCannotPartiallyWrite() async throws {
        let bundle = try await makeBatchFixture(additionalFixtureSQL: """
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, cleared, reconciled, transferred_id, isChild)
                VALUES ('split-root', 'checking', 20260705, -300, 'groceries', 0, NULL, 1,
                        'Coffee Shop', 0, 0, NULL, 0);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, cleared, reconciled, transferred_id, isChild)
                VALUES ('split-child', 'checking', 20260705, -300, 'groceries', 0, 'split-root', 0,
                        'Coffee Shop', 0, 0, NULL, 1);
            """)
        let selections = [identity("txn"), identity("split-root")]
        let database = try bundle.store.requireDatabase(for: "group-1")
        let clockBefore = await database.localClock
        let review = try await bundle.store.reviewTransactionBatch(
            context: context(for: bundle.store), intent: .categorize(categoryID: "utilities"),
            selections: selections
        )
        #expect(review.blockedCount == 1)
        #expect(!review.canSubmit)
        do {
            _ = try await bundle.store.commitTransactionBatch(review: review, authorization: nil)
            Issue.record("Expected the blocked batch to reject as a whole")
        } catch let error as LocalFirstError {
            #expect(error.errorDescription != nil)
        } catch {
            Issue.record("Unexpected error for blocked batch: \(error)")
        }
        let category = try readRows(bundle) { db in
            try String.fetchOne(db, sql: "SELECT category FROM transactions WHERE id = 'txn'")
        }
        #expect(category == "groceries")
        #expect(try await database.recentBudgetActions().isEmpty)
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        #expect(await database.localClock == clockBefore)
    }

    @Test func categorizationDatabaseFailureIsNotMisreportedAsBlockedGraph() async throws {
        let bundle = try await makeBatchFixture(additionalFixtureSQL: """
            UPDATE transactions SET description = 'xfer-credit' WHERE id = 'txn';
            """)
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: "DROP TABLE payees")
            try db.execute(sql: "CREATE TABLE payees (transfer_acct TEXT)")
        }
        // A missing accounts table is intentionally tolerated by accountOffBudget.
        // An incomplete payees table instead makes categorization validation's
        // transfer lookup surface the underlying SQLite schema error.

        do {
            _ = try await bundle.store.reviewTransactionBatch(
                context: context(for: bundle.store), intent: .categorize(categoryID: "utilities"),
                selections: [identity("txn")]
            )
            Issue.record("Expected SQLite failure from categorization validation")
        } catch is LocalFirstError {
            Issue.record("Unexpectedly converted a storage error into a product-level batch response")
        } catch {
            // The underlying GRDB/SQLite error should propagate to the caller.
        }
    }

    @Test func batchCommitAndUndoCannotWriteAfterSessionInvalidation() async throws {
        let bundle = try await makeBatchFixture(additionalFixtureSQL: """
            UPDATE transactions SET cleared = 0, reconciled = 0 WHERE id = 'txn';
            """)
        let database = try #require(bundle.store.database)
        let review = try await bundle.store.reviewTransactionBatch(
            context: context(for: bundle.store), intent: .clear, selections: [identity("txn")]
        )
        database.invalidateSessionWrites()
        do {
            _ = try await database.commitTransactionBatch(review: review, authorization: nil)
            Issue.record("Expected a closed session to reject batch commit")
        } catch let error as LocalFirstError {
            #expect(error == .budgetNotOpened)
        }

        let reopened = try await makeBatchFixture(additionalFixtureSQL: """
            UPDATE transactions SET cleared = 0, reconciled = 0 WHERE id = 'txn';
            """)
        let reopenedDB = try #require(reopened.store.database)
        let liveReview = try await reopened.store.reviewTransactionBatch(
            context: context(for: reopened.store), intent: .clear, selections: [identity("txn")]
        )
        _ = try await reopened.store.commitTransactionBatch(review: liveReview, authorization: nil)
        let record = try #require(try await reopenedDB.actionLogRecord(id: liveReview.id))
        reopenedDB.invalidateSessionWrites()
        do {
            _ = try await reopenedDB.commitActionUndo(record: record)
            Issue.record("Expected a closed session to reject batch undo")
        } catch let error as LocalFirstError {
            #expect(error == .budgetNotOpened)
        }
        #expect(try await reopenedDB.actionLogRecord(id: liveReview.id)?.status == .applied)
    }

    @Test func cancelledBatchCommitIsRejectedBeforeDatabaseWrite() async throws {
        let bundle = try await makeBatchFixture(additionalFixtureSQL: """
            UPDATE transactions SET cleared = 0, reconciled = 0 WHERE id = 'txn';
            """)
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await database.reviewTransactionBatch(
            context: context(for: bundle.store), intent: .clear, selections: [identity("txn")]
        )
        let clockBefore = await database.localClock
        let cancelledCommit = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await database.commitTransactionBatch(review: review, authorization: nil)
        }
        do {
            _ = try await cancelledCommit.value
            Issue.record("Expected cancellation before the batch write")
        } catch is CancellationError { }

        #expect(await database.localClock == clockBefore)
        #expect(try await database.recentBudgetActions().isEmpty)
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == 0)
    }

    @Test func sameBudgetReopenRejectsOldReviewButAcceptsFreshGeneration() async throws {
        let bundle = try await makeBatchFixture(additionalFixtureSQL: """
            UPDATE transactions SET cleared = 0, reconciled = 0 WHERE id = 'txn';
            """)
        let store = bundle.store
        let oldContext = context(for: store)
        let oldReview = try await store.reviewTransactionBatch(
            context: oldContext, intent: .clear, selections: [identity("txn")]
        )
        let previousGeneration = store.budgetSessionGeneration
        store.closeOpenBudget()
        _ = try await store.openCachedBudget(bundle.budget)
        #expect(store.budgetSessionGeneration != previousGeneration)

        await #expect(throws: CancellationError.self) {
            try await store.commitTransactionBatch(review: oldReview, authorization: nil)
        }
        #expect(try await store.recentBudgetActions(budgetID: "group-1").isEmpty)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") == 0)
        #expect(try readRows(bundle) { db in
            try Int.fetchOne(db, sql: "SELECT cleared FROM transactions WHERE id = 'txn'")
        } == 0)

        let freshReview = try await store.reviewTransactionBatch(
            context: context(for: store), intent: .clear, selections: [identity("txn")]
        )
        let outcome = try await store.commitTransactionBatch(review: freshReview, authorization: nil)
        #expect(outcome.receipt.actionID == freshReview.id)
        #expect(try await store.recentBudgetActions(budgetID: "group-1").count == 1)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") > 0)
    }

    @Test func sessionCloseDuringPostCommitRefreshReturnsDurablePendingOutcome() async throws {
        let gate = TransactionBatchRefreshGate()
        let bundle = try await makeBatchFixture(
            additionalFixtureSQL: "UPDATE transactions SET cleared = 0, reconciled = 0 WHERE id = 'txn';",
            transactionFeedPageReadHook: { _, _, _, _ in await gate.pause() }
        )
        let database = try #require(bundle.store.database)
        let review = try await bundle.store.reviewTransactionBatch(
            context: context(for: bundle.store), intent: .clear, selections: [identity("txn")]
        )
        let commit = Task { try await bundle.store.commitTransactionBatch(review: review, authorization: nil) }
        guard await gate.waitForEntry() else {
            gate.release()
            _ = try? await commit.value
            Issue.record("The post-commit refresh did not reach its bounded gate")
            return
        }
        bundle.store.closeOpenBudget()
        gate.release()

        let outcome = try await commit.value
        #expect(outcome.receipt.actionID == review.id)
        #expect(outcome.refreshPending)
        #expect(!outcome.sessionCurrent)
        #expect(try await database.actionLogRecord(id: review.id)?.status == .applied)
    }

    @Test func callerCancellationDuringRefreshStillReturnsDurableReceipt() async throws {
        let gate = TransactionBatchRefreshGate()
        let bundle = try await makeBatchFixture(
            additionalFixtureSQL: "UPDATE transactions SET cleared = 0, reconciled = 0 WHERE id = 'txn';",
            transactionFeedPageReadHook: { _, _, _, _ in await gate.pause() }
        )
        let database = try #require(bundle.store.database)
        let review = try await bundle.store.reviewTransactionBatch(
            context: context(for: bundle.store), intent: .clear,
            selections: [identity("txn")]
        )
        let commit = Task { try await bundle.store.commitTransactionBatch(review: review, authorization: nil) }
        guard await gate.waitForEntry() else {
            gate.release()
            _ = try? await commit.value
            Issue.record("The post-commit refresh did not reach its bounded gate")
            return
        }

        commit.cancel()
        gate.release()
        let outcome = try await commit.value
        #expect(outcome.receipt.actionID == review.id)
        #expect(!outcome.refreshPending)
        #expect(outcome.sessionCurrent)
        #expect(try await database.actionLogRecord(id: review.id)?.status == .applied)
    }

    @Test func failedRefreshInvalidatesPossiblyStaleFeedCache() async throws {
        let behavior = TransactionBatchRefreshBehavior()
        let bundle = try await makeBatchFixture(
            additionalFixtureSQL: "UPDATE transactions SET cleared = 0, reconciled = 0 WHERE id = 'txn';",
            transactionFeedPageReadHook: { _, _, _, _ in
                if behavior.failReads { throw TransactionBatchRefreshError.expectedFailure }
            }
        )
        let store = bundle.store
        try await store.refreshAccountTransactions(budgetID: "group-1", accountID: "checking")
        #expect(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking") != nil)
        behavior.failReads = true

        let review = try await store.reviewTransactionBatch(
            context: context(for: store), intent: .clear,
            selections: [identity("txn")]
        )
        let outcome = try await store.commitTransactionBatch(review: review, authorization: nil)
        #expect(outcome.refreshPending)
        #expect(outcome.sessionCurrent)
        #expect(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking") == nil)
        #expect(try await store.recentBudgetActions(budgetID: "group-1").count == 1)
    }

    @Test func deletedSplitBatchUndoBlocksWhenGraphMembershipChanges() async throws {
        let bundle = try await makeBatchFixture(additionalFixtureSQL: """
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, cleared, reconciled, transferred_id, isChild)
                VALUES ('split-root', 'checking', 20260705, -300, 'groceries', 0, NULL, 1,
                        'Coffee Shop', 0, 0, NULL, 0);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, cleared, reconciled, transferred_id, isChild)
                VALUES ('split-child', 'checking', 20260705, -300, 'groceries', 0, 'split-root', 0,
                        'Coffee Shop', 0, 0, NULL, 1);
            """)
        let database = try #require(bundle.store.database)
        let review = try await bundle.store.reviewTransactionBatch(
            context: context(for: bundle.store), intent: .delete, selections: [identity("split-root")]
        )
        _ = try await bundle.store.commitTransactionBatch(review: review, authorization: nil)
        let deletedGraph = try readRows(bundle) { db in
            (
                try Int.fetchOne(db, sql: "SELECT tombstone FROM transactions WHERE id = 'split-root'"),
                try Int.fetchOne(db, sql: "SELECT tombstone FROM transactions WHERE id = 'split-child'"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actualist_action_log")
            )
        }
        #expect(deletedGraph.0 == 1)
        #expect(deletedGraph.1 == 1)
        #expect(deletedGraph.2 == 1)
        let record = try #require(try await database.actionLogRecord(id: review.id))
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        let externalQueue = try DatabaseQueue(path: url.path)
        try await externalQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                          description, cleared, reconciled, transferred_id, isChild)
                    VALUES ('late-child', 'checking', 20260705, -1, 'groceries', 0, 'split-root', 0,
                            'Coffee Shop', 0, 0, NULL, 1)
                """)
        }

        let preview = try await database.actionUndoPreview(record: record)
        guard preview.block == .batchChanged else {
            Issue.record("Expected Undo to reject a changed split graph")
            return
        }
    }

    func context(for store: LocalFirstActualStore) -> TransactionSelectionContext {
        TransactionSelectionContext(
            budgetID: "group-1", sessionGeneration: store.budgetSessionGeneration,
            scope: .spending,
            querySignature: TransactionFeedQuery().signature
        )
    }

    func makeBatchFixture(
        additionalFixtureSQL: String = "",
        transactionFeedPageReadHook: TransactionFeedPageReadHook? = nil
    ) async throws -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        try await support.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: "ALTER TABLE transactions ADD COLUMN reconciled INTEGER;\n\(additionalFixtureSQL)",
            transactionFeedPageReadHook: transactionFeedPageReadHook
        )
    }

    func identity(_ id: String) -> TransactionSelectionIdentity {
        TransactionSelectionIdentity(transactionID: id, familyRootID: id, role: .root)!
    }

    func readRows<T>(
        _ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle,
        _ read: (Database) throws -> T
    ) throws -> T {
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read(read)
    }

    private func persistenceState(
        _ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle
    ) async throws -> BatchPersistenceState {
        let database = try #require(bundle.store.database)
        let clock = await database.localClock
        let outboxMessages = try await database.pendingLocalSyncMessageCount()
        let historyRows = try await database.recentBudgetActions().count
        return try readRows(bundle) { db in
            BatchPersistenceState(
                transactions: try String.fetchAll(db, sql: """
                    SELECT id || '|' || COALESCE(category, '') || '|' || COALESCE(transferred_id, '') || '|'
                           || COALESCE(tombstone, 0)
                    FROM transactions ORDER BY id
                    """),
                categories: try String.fetchAll(db, sql: """
                    SELECT id || '|' || name || '|' || COALESCE(tombstone, 0)
                    FROM categories ORDER BY id
                    """),
                crdtMessages: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0,
                outboxMessages: outboxMessages,
                historyRows: historyRows,
                clock: clock
            )
        }
    }
}

private struct BatchPersistenceState: Equatable {
    let transactions: [String]
    let categories: [String]
    let crdtMessages: Int
    let outboxMessages: Int
    let historyRows: Int
    let clock: HybridLogicalClock?
}

@MainActor
private final class TransactionBatchRefreshGate {
    private let entered = TestLatch()
    private let released = TestLatch()
    private var didEnter = false
    private var didTimeOut = false

    func pause() async {
        didEnter = true
        entered.trip()
        await released.wait()
    }

    func waitForEntry(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, !self.didEnter else { return }
            self.didTimeOut = true
            self.released.trip()
            self.entered.trip()
        }
        await entered.wait()
        deadline.cancel()
        return didEnter && !didTimeOut
    }

    func release() { released.trip() }
}

@MainActor
private final class TransactionBatchRefreshBehavior {
    var failReads = false
}

private enum TransactionBatchRefreshError: Error {
    case expectedFailure
}
