import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct TransactionMergeMutationTests {
    private let support = LocalFirstActualStoreTests()

    @Test func exactTieKeepsSecondOrderedInputAndWritesOneCompleteHistoryAction() async throws {
        let bundle = try await makeMergeFixture(additionalFixtureSQL: simpleSecondRowSQL)
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await database.reviewTransactionMerge(
            context: context(for: bundle.store),
            orderedTransactionIDs: ["txn", "second"]
        )
        #expect(review.orderedTransactionIDs == ["txn", "second"])
        #expect(review.keptRow?.transactionID == "second")
        #expect(review.droppedRow?.transactionID == "txn")
        #expect(review.canSubmit)

        let receipt = try await database.commitTransactionMerge(review: review, authorization: nil)
        #expect(receipt.actionID == review.id)
        #expect(receipt.changedAccountIDs == ["checking"])
        #expect(receipt.changedMonths == ["2026-07"])
        #expect(receipt.changedTransactionIDs == ["second", "txn"])
        #expect(try readRows(bundle) { db in
            try Int.fetchOne(db, sql: "SELECT tombstone FROM transactions WHERE id = 'txn'")
        } == 1)
        #expect(try readRows(bundle) { db in
            try Int.fetchOne(db, sql: "SELECT tombstone FROM transactions WHERE id = 'second'")
        } == 0)

        let actions = try await database.recentBudgetActions()
        #expect(actions.count == 1)
        let action = try #require(actions.first)
        #expect(action.kind == .transactionMerge)
        guard case .transactionMerge(let inverse) = action.inverse else {
            Issue.record("Expected a merge inverse containing both complete source graphs")
            return
        }
        #expect(inverse.beforeSnapshots.map(\.id) == ["second", "txn"])
        #expect(inverse.afterSnapshots.map(\.id) == ["second", "txn"])
        #expect(inverse.afterSnapshots.first { $0.id == "txn" }?.tombstone == true)
        #expect(inverse.afterSnapshots.first { $0.id == "second" }?.tombstone == false)
    }

    @Test func reversingExactTieInputsReversesTheKeeper() async throws {
        for (orderedIDs, expectedKeeper) in [
            (["txn", "second"], "second"),
            (["second", "txn"], "txn"),
        ] {
            let bundle = try await makeMergeFixture(additionalFixtureSQL: simpleSecondRowSQL)
            let database = try bundle.store.requireDatabase(for: "group-1")
            let review = try await database.reviewTransactionMerge(
                context: context(for: bundle.store),
                orderedTransactionIDs: orderedIDs
            )
            #expect(review.orderedTransactionIDs == orderedIDs)
            #expect(review.keptRow?.transactionID == expectedKeeper)
            _ = try await database.commitTransactionMerge(review: review, authorization: nil)
            #expect(try await database.actionLogRecord(id: review.id)?.status == .applied)
        }
    }

    @Test func aggregateReconciliationCoversAdoptedSplitChildAndTransferPeer() async throws {
        let bundle = try await makeMergeFixture(additionalFixtureSQL: """
            UPDATE transactions SET date = 20260702, reconciled = 0 WHERE id = 'txn';
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('split-root', 'checking', 20260703, -1000, NULL, 0, NULL, 1,
                        NULL, NULL, 0, 0, NULL, 0, NULL, NULL);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('split-child', 'checking', 20260703, -1000, NULL, 0, 'split-root', 0,
                        'xfer-credit', NULL, 0, 1, 'split-peer', 1, -1, NULL);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('split-peer', 'credit', 20260703, 1000, NULL, 0, NULL, 0,
                        'xfer-checking', NULL, 0, 1, 'split-child', 0, NULL, NULL);
            """)
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await database.reviewTransactionMerge(
            context: context(for: bundle.store),
            orderedTransactionIDs: ["txn", "split-root"]
        )
        #expect(review.keptRow?.transactionID == "txn")
        #expect(review.reconciledTransactionIDs == ["split-child", "split-peer"])
        let beforeCommit = try await persistenceState(bundle, database: database)

        await #expect(throws: LocalFirstError.self) {
            try await database.commitTransactionMerge(review: review, authorization: nil)
        }
        #expect(try await persistenceState(bundle, database: database) == beforeCommit)

        let authorization = TransactionMergeAuthorization(
            reviewID: review.id,
            reviewFingerprint: review.reviewFingerprint,
            reconciledTransactionIDs: review.reconciledTransactionIDs
        )
        let receipt = try await database.commitTransactionMerge(review: review, authorization: authorization)
        #expect(receipt.changedTransactionIDs == ["split-child", "split-peer", "split-root", "txn"])
        #expect(try readRows(bundle) { db in
            try String.fetchOne(db, sql: "SELECT parent_id FROM transactions WHERE id = 'split-child'")
        } == "txn")
        #expect(try readRows(bundle) { db in
            try Int.fetchOne(db, sql: "SELECT tombstone FROM transactions WHERE id = 'split-root'")
        } == 1)
    }

    @Test func reconciliationAddedAfterReviewInvalidatesTheFingerprintAndAuthorization() async throws {
        let bundle = try await makeMergeFixture(additionalFixtureSQL: """
            UPDATE transactions SET amount = -1000, reconciled = 0 WHERE id = 'txn';
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('second', 'checking', 20260703, -1000, 'groceries', 0, NULL, 0,
                        'coffee', NULL, 0, 0, NULL, 0, NULL, NULL);
            """)
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await database.reviewTransactionMerge(
            context: context(for: bundle.store),
            orderedTransactionIDs: ["txn", "second"]
        )
        try mutateDatabase(bundle, sql: "UPDATE transactions SET reconciled = 1 WHERE id = 'second'")
        let afterReconciliation = try await persistenceState(bundle, database: database)

        await #expect(throws: LocalFirstError.self) {
            try await database.commitTransactionMerge(review: review, authorization: nil)
        }
        #expect(try await persistenceState(bundle, database: database) == afterReconciliation)
    }

    @Test func childAndPeerReconciledAfterReviewRequireFreshAggregateAuthorization() async throws {
        let bundle = try await makeMergeFixture(additionalFixtureSQL: """
            UPDATE transactions SET date = 20260702, reconciled = 0 WHERE id = 'txn';
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('split-root', 'checking', 20260703, -1000, NULL, 0, NULL, 1,
                        NULL, NULL, 0, 0, NULL, 0, NULL, NULL);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('split-child', 'checking', 20260703, -1000, NULL, 0, 'split-root', 0,
                        'xfer-credit', NULL, 0, 0, 'split-peer', 1, -1, NULL);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('split-peer', 'credit', 20260703, 1000, NULL, 0, NULL, 0,
                        'xfer-checking', NULL, 0, 0, 'split-child', 0, NULL, NULL);
            """)
        let database = try bundle.store.requireDatabase(for: "group-1")
        let staleReview = try await database.reviewTransactionMerge(
            context: context(for: bundle.store),
            orderedTransactionIDs: ["txn", "split-root"]
        )
        try mutateDatabase(
            bundle,
            sql: "UPDATE transactions SET reconciled = 1 WHERE id IN ('split-child', 'split-peer')"
        )
        let afterReconciliation = try await persistenceState(bundle, database: database)

        await #expect(throws: LocalFirstError.self) {
            try await database.commitTransactionMerge(review: staleReview, authorization: nil)
        }
        #expect(try await persistenceState(bundle, database: database) == afterReconciliation)

        let freshReview = try await database.reviewTransactionMerge(
            context: context(for: bundle.store),
            orderedTransactionIDs: ["txn", "split-root"]
        )
        #expect(freshReview.reconciledTransactionIDs == ["split-child", "split-peer"])
        let authorization = TransactionMergeAuthorization(
            reviewID: freshReview.id,
            reviewFingerprint: freshReview.reviewFingerprint,
            reconciledTransactionIDs: freshReview.reconciledTransactionIDs
        )
        _ = try await database.commitTransactionMerge(review: freshReview, authorization: authorization)
    }

    @Test(arguments: ["account", "amount", "date"])
    func changedSourceIdentityAfterReviewRejectsTheMerge(_ field: String) async throws {
        let bundle = try await makeMergeFixture(additionalFixtureSQL: simpleSecondRowSQL)
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await database.reviewTransactionMerge(
            context: context(for: bundle.store),
            orderedTransactionIDs: ["txn", "second"]
        )
        let mutation: String
        switch field {
        case "account": mutation = "UPDATE transactions SET acct = 'savings' WHERE id = 'txn'"
        case "amount": mutation = "UPDATE transactions SET amount = -999 WHERE id = 'txn'"
        case "date": mutation = "UPDATE transactions SET date = 20260803 WHERE id = 'txn'"
        default:
            Issue.record("Unknown source mutation: \(field)")
            return
        }
        try mutateDatabase(bundle, sql: mutation)
        let afterSourceChange = try await persistenceState(bundle, database: database)

        await #expect(throws: LocalFirstError.self) {
            try await database.commitTransactionMerge(review: review, authorization: nil)
        }
        #expect(try await persistenceState(bundle, database: database) == afterSourceChange)
    }

    @Test func staleTransferPayeeDestinationIsRejectedWithoutWriting() async throws {
        let bundle = try await makeMergeFixture(additionalFixtureSQL: """
            UPDATE transactions SET description = 'xfer-credit', transferred_id = 'transfer-peer'
                WHERE id = 'txn';
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('transfer-peer', 'credit', 20260703, 1000, NULL, 0, NULL, 0,
                        'xfer-checking', NULL, 0, 0, 'txn', 0, NULL, NULL);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('simple', 'checking', 20260703, -1000, 'groceries', 0, NULL, 0,
                        'coffee', NULL, 0, 0, NULL, 0, NULL, NULL);
            """)
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await database.reviewTransactionMerge(
            context: context(for: bundle.store),
            orderedTransactionIDs: ["txn", "simple"]
        )
        try mutateDatabase(bundle, sql: "UPDATE payees SET transfer_acct = 'savings' WHERE id = 'xfer-credit'")
        let afterDestinationChange = try await persistenceState(bundle, database: database)

        await #expect(throws: LocalFirstError.self) {
            try await database.commitTransactionMerge(review: review, authorization: nil)
        }
        #expect(try await persistenceState(bundle, database: database) == afterDestinationChange)
    }

    @Test func selectedChildAndStoredSplitErrorAreBlockedByDatabaseReview() async throws {
        let childBundle = try await makeMergeFixture(additionalFixtureSQL: """
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('split-root', 'checking', 20260703, -1000, NULL, 0, NULL, 1,
                        NULL, NULL, 0, 0, NULL, 0, NULL, NULL);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('split-child', 'checking', 20260703, -1000, 'groceries', 0, 'split-root', 0,
                        'coffee', NULL, 0, 0, NULL, 1, -1, NULL);
            """)
        let childDatabase = try childBundle.store.requireDatabase(for: "group-1")
        let childReview = try await childDatabase.reviewTransactionMerge(
            context: context(for: childBundle.store),
            orderedTransactionIDs: ["split-child", "txn"]
        )
        #expect(childReview.blockedReason == .selectedChild("split-child"))
        #expect(!childReview.canSubmit)
        #expect(childReview.inputRows.map(\.transactionID) == ["split-child", "txn"])

        let errorBundle = try await makeMergeFixture(additionalFixtureSQL: """
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('error-root', 'checking', 20260703, -1000, NULL, 0, NULL, 1,
                        NULL, NULL, 0, 0, NULL, 0, NULL,
                        '{"type":"SplitTransactionError","version":1,"difference":1}');
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('error-child', 'checking', 20260703, -1000, 'groceries', 0, 'error-root', 0,
                        'coffee', NULL, 0, 0, NULL, 1, -1, NULL);
            """)
        let errorDatabase = try errorBundle.store.requireDatabase(for: "group-1")
        let errorReview = try await errorDatabase.reviewTransactionMerge(
            context: context(for: errorBundle.store),
            orderedTransactionIDs: ["error-root", "txn"]
        )
        #expect(errorReview.blockedReason == .splitHasError("error-root"))
        #expect(!errorReview.canSubmit)
    }

    @Test func overlappingTransferGraphsReturnBlockedReview() async throws {
        let bundle = try await makeMergeFixture(additionalFixtureSQL: """
            UPDATE transactions SET description = 'xfer-credit', transferred_id = 'transfer-peer'
                WHERE id = 'txn';
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('transfer-peer', 'credit', 20260703, 1000, NULL, 0, NULL, 0,
                        'xfer-checking', NULL, 0, 0, 'txn', 0, NULL, NULL);
            """)
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await database.reviewTransactionMerge(
            context: context(for: bundle.store),
            orderedTransactionIDs: ["txn", "transfer-peer"]
        )
        #expect(!review.canSubmit)
        #expect(review.blockedReason == .overlappingGraphs(["transfer-peer", "txn"]))
        let beforeCommit = try await persistenceState(bundle, database: database)
        await #expect(throws: LocalFirstError.self) {
            try await database.commitTransactionMerge(review: review, authorization: nil)
        }
        #expect(try await persistenceState(bundle, database: database) == beforeCommit)
    }

    @Test func malformedNonreciprocalGraphIsRejectedDuringReview() async throws {
        let graphMutations = [
            "UPDATE transactions SET transferred_id = 'missing-peer' WHERE id = 'txn'",
            """
            UPDATE transactions SET description = 'xfer-credit', transferred_id = 'transfer-peer'
                WHERE id = 'txn';
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('transfer-peer', 'credit', 20260703, 1000, NULL, 0, NULL, 0,
                        'xfer-checking', NULL, 0, 0, NULL, 0, NULL, NULL);
            """,
        ]
        for mutation in graphMutations {
            let bundle = try await makeMergeFixture(additionalFixtureSQL: mutation)
            let database = try bundle.store.requireDatabase(for: "group-1")
            let beforeReview = try await persistenceState(bundle, database: database)
            await #expect(throws: LocalFirstError.self) {
                try await database.reviewTransactionMerge(
                    context: context(for: bundle.store),
                    orderedTransactionIDs: ["txn", "second"]
                )
            }
            #expect(try await persistenceState(bundle, database: database) == beforeReview)
        }
    }

    @Test func invalidSecondTransferPairProducesNoClockOutboxRowOrHistoryChanges() async throws {
        let bundle = try await makeMergeFixture(additionalFixtureSQL: """
            UPDATE transactions SET description = 'xfer-credit', transferred_id = 'peer-a'
                WHERE id = 'txn';
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('peer-a', 'credit', 20260702, 1000, NULL, 0, NULL, 1,
                        'xfer-checking', NULL, 0, 0, 'txn', 0, NULL, NULL);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('peer-a-child', 'credit', 20260702, 1000, NULL, 0, 'peer-a', 0,
                        'coffee', NULL, 0, 0, NULL, 1, -1, NULL);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('root-b', 'checking', 20260703, -1000, NULL, 0, NULL, 0,
                        'xfer-credit', NULL, 0, 0, 'peer-b', 0, NULL, NULL);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('peer-b', 'credit', 20260703, 1000, 'groceries', 0, NULL, 0,
                        'xfer-checking', NULL, 0, 0, 'root-b', 0, NULL, NULL);
            """)
        let database = try bundle.store.requireDatabase(for: "group-1")
        let beforeCommit = try await persistenceState(bundle, database: database)
        let review = try await database.reviewTransactionMerge(
            context: context(for: bundle.store),
            orderedTransactionIDs: ["txn", "root-b"]
        )
        #expect(review.blockedReason == .invalidProposedParentFields("peer-a"))
        #expect(!review.canSubmit)

        await #expect(throws: LocalFirstError.self) {
            try await database.commitTransactionMerge(review: review, authorization: nil)
        }
        #expect(try await persistenceState(bundle, database: database) == beforeCommit)
    }

    @Test func addedSplitMembershipAfterReviewRejectsCommit() async throws {
        let bundle = try await makeMergeFixture(additionalFixtureSQL: simpleSecondRowSQL)
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await database.reviewTransactionMerge(
            context: context(for: bundle.store),
            orderedTransactionIDs: ["txn", "second"]
        )
        try mutateDatabase(bundle, sql: """
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('late-child', 'checking', 20260703, -1, 'groceries', 0, 'txn', 0,
                        'coffee', NULL, 0, 0, NULL, 1, -1, NULL);
            """)
        let afterMembershipChange = try await persistenceState(bundle, database: database)

        await #expect(throws: LocalFirstError.self) {
            try await database.commitTransactionMerge(review: review, authorization: nil)
        }
        #expect(try await persistenceState(bundle, database: database) == afterMembershipChange)
    }

    @Test func injectedApplyFailureRollsBackTheMergeAndActionLog() async throws {
        let bundle = try await makeMergeFixture(additionalFixtureSQL: simpleSecondRowSQL)
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        let database = try BudgetDatabase(
            databaseURL: url,
            localNodeID: "merge-failure",
            beforeBudgetDataMutation: { throw TransactionMergeInjectedFailure.expected }
        )
        let review = try await database.reviewTransactionMerge(
            context: context(for: bundle.store),
            orderedTransactionIDs: ["txn", "second"]
        )
        let beforeCommit = try await persistenceState(bundle, database: database)

        await #expect(throws: LocalFirstError.self) {
            try await database.commitTransactionMerge(review: review, authorization: nil)
        }
        #expect(try await persistenceState(bundle, database: database) == beforeCommit)
    }

    @Test func transactionApplyFailureRollsBackMessagesOutboxClockAndHistory() async throws {
        let bundle = try await makeMergeFixture(additionalFixtureSQL: simpleSecondRowSQL)
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await database.reviewTransactionMerge(
            context: context(for: bundle.store),
            orderedTransactionIDs: ["txn", "second"]
        )
        try mutateDatabase(bundle, sql: """
            CREATE TRIGGER reject_merge_tombstone BEFORE UPDATE OF tombstone ON transactions
            WHEN NEW.id = 'txn'
            BEGIN SELECT RAISE(ABORT, 'injected merge failure'); END;
            """)
        let beforeCommit = try await persistenceState(bundle, database: database)

        await #expect(throws: LocalFirstError.self) {
            try await database.commitTransactionMerge(review: review, authorization: nil)
        }
        #expect(try await persistenceState(bundle, database: database) == beforeCommit)
    }

    @Test func cancellationAndSessionInvalidationRejectBeforeWriting() async throws {
        let cancelledBundle = try await makeMergeFixture(additionalFixtureSQL: simpleSecondRowSQL)
        let cancelledDatabase = try cancelledBundle.store.requireDatabase(for: "group-1")
        let cancelledReview = try await cancelledDatabase.reviewTransactionMerge(
            context: context(for: cancelledBundle.store),
            orderedTransactionIDs: ["txn", "second"]
        )
        let beforeCancellation = try await persistenceState(cancelledBundle, database: cancelledDatabase)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cancelledDatabase.commitTransactionMerge(
                review: cancelledReview,
                authorization: nil
            )
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancelled merge commit to stop before writing")
        } catch is CancellationError { }
        #expect(try await persistenceState(cancelledBundle, database: cancelledDatabase) == beforeCancellation)

        let closedBundle = try await makeMergeFixture(additionalFixtureSQL: simpleSecondRowSQL)
        let closedDatabase = try closedBundle.store.requireDatabase(for: "group-1")
        let closedReview = try await closedDatabase.reviewTransactionMerge(
            context: context(for: closedBundle.store),
            orderedTransactionIDs: ["txn", "second"]
        )
        let beforeClose = try await persistenceState(closedBundle, database: closedDatabase)
        closedDatabase.invalidateSessionWrites()
        await #expect(throws: LocalFirstError.self) {
            try await closedDatabase.commitTransactionMerge(review: closedReview, authorization: nil)
        }
        #expect(try await persistenceState(closedBundle, database: closedDatabase) == beforeClose)
    }

    private var simpleSecondRowSQL: String {
        """
        INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                  description, notes, cleared, reconciled, transferred_id, isChild,
                                  sort_order, error)
            VALUES ('second', 'checking', 20260703, -1000, 'groceries', 0, NULL, 0,
                    'coffee', NULL, 0, 0, NULL, 0, NULL, NULL);
        """
    }

    private func makeMergeFixture(
        additionalFixtureSQL: String = ""
    ) async throws -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        try await support.makeOpenedWritableStoreBundle(
            keychainBackend: FakeKeychainBackend(),
            additionalFixtureSQL: """
            ALTER TABLE transactions ADD COLUMN reconciled INTEGER;
            ALTER TABLE transactions ADD COLUMN sort_order REAL;
            ALTER TABLE transactions ADD COLUMN error TEXT;
            UPDATE transactions SET date = 20260703, amount = -1000, reconciled = 0 WHERE id = 'txn';
            \(additionalFixtureSQL)
            """
        )
    }

    private func context(for store: LocalFirstActualStore) -> TransactionSelectionContext {
        TransactionSelectionContext(
            budgetID: "group-1",
            sessionGeneration: store.budgetSessionGeneration,
            scope: .spending,
            querySignature: TransactionFeedQuery.all.signature
        )
    }

    private func mutateDatabase(
        _ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle,
        sql: String
    ) throws {
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in try db.execute(sql: sql) }
    }

    private func readRows<T>(
        _ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle,
        _ read: (Database) throws -> T
    ) throws -> T {
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read(read)
    }

    private func persistenceState(
        _ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle,
        database suppliedDatabase: BudgetDatabase? = nil
    ) async throws -> MergePersistenceState {
        let database: BudgetDatabase
        if let suppliedDatabase {
            database = suppliedDatabase
        } else {
            database = try bundle.store.requireDatabase(for: "group-1")
        }
        return MergePersistenceState(
            transactions: try readRows(bundle) { db in
                try String.fetchAll(db, sql: """
                    SELECT id || '|' || COALESCE(acct, '') || '|' || COALESCE(date, 0) || '|'
                           || COALESCE(amount, 0) || '|' || COALESCE(description, '') || '|'
                           || COALESCE(category, '') || '|' || COALESCE(reconciled, 0) || '|'
                           || COALESCE(tombstone, 0) || '|' || COALESCE(parent_id, '') || '|'
                           || COALESCE(is_parent, 0) || '|' || COALESCE(isChild, 0) || '|'
                           || COALESCE(transferred_id, '')
                    FROM transactions ORDER BY id
                    """)
            },
            crdtMessageCount: try readRows(bundle) { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0
            },
            outboxMessageCount: try await database.pendingLocalSyncMessageCount(),
            historyCount: try await database.recentBudgetActions().count,
            clock: await database.localClock
        )
    }
}

private struct MergePersistenceState: Equatable {
    let transactions: [String]
    let crdtMessageCount: Int
    let outboxMessageCount: Int
    let historyCount: Int
    let clock: HybridLogicalClock?
}

private enum TransactionMergeInjectedFailure: Error, Sendable {
    case expected
}
