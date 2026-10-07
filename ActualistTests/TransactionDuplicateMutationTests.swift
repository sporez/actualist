import Foundation
import GRDB
import Synchronization
import Testing
@testable import Actualist

@MainActor
@Suite("Transaction duplicate database mutation")
struct TransactionDuplicateMutationTests {
    private let support = LocalFirstActualStoreTests()

    @Test func duplicateCommitCopiesCompleteRowResetsStatusAndRecordsOneUndoableAction() async throws {
        let bundle = try await makeBundle(additionalFixtureSQL: """
            UPDATE transactions SET cleared = 1, reconciled = 1, notes = 'source note'
            WHERE id = 'txn';
            """)
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await database.reviewTransactionDuplicate(
            context: context(bundle.store),
            selections: [identity("txn")],
            cloneIDAtIndex: { _ in "fractional-order-clone" },
            now: Date(timeIntervalSince1970: 123.00025)
        )

        #expect(review.canSubmit)
        #expect(review.allocations.count == 1)
        #expect(review.groups.count == 1)
        let cloneID = try #require(review.allocations.first?.duplicateTransactionID)
        let allocatedOrder = try #require(review.allocations.first?.sortOrder)
        #expect(allocatedOrder.rounded(.towardZero) != allocatedOrder)
        let receipt = try await database.commitTransactionDuplicate(review: review)

        #expect(receipt.actionID == review.id)
        #expect(receipt.changed.accounts == ["checking"])
        #expect(receipt.changed.months == ["2026-07"])
        #expect(receipt.changed.transactions == ["txn", cloneID].sorted())
        let clone = try #require(try transactionState(cloneID, bundle: bundle))
        #expect(clone.accountID == "checking")
        #expect(clone.amount == -12_345)
        #expect(clone.categoryID == "groceries")
        #expect(clone.notes == "source note")
        #expect(clone.cleared == 0)
        #expect(clone.reconciled == 0)
        #expect(clone.tombstone == 0)
        #expect(clone.sortOrder?.bitPattern == allocatedOrder.bitPattern)

        let records = try await database.recentBudgetActions()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.id == review.id)
        #expect(record.kind == .transactionDuplicate)
        guard case .transactionDuplicate(let summary) = record.summary,
              case .transactionDuplicate(let inverse) = record.inverse else {
            Issue.record("Expected one complete duplicate History action")
            return
        }
        #expect(summary.selectedSourceTransactionIDs == ["txn"])
        #expect(summary.duplicateTransactionIDs == [cloneID])
        #expect(inverse.afterSnapshots.map(\.id) == [cloneID])

        let undo = try await database.actionUndoPreview(record: record)
        #expect(undo.block == nil)
        try await database.commitActionUndo(record: record)
        #expect(try transactionState(cloneID, bundle: bundle)?.tombstone == 1)
    }

    @Test func overlappingSelectedSplitFamilyIsClonedOnceWithClosedMembership() async throws {
        let bundle = try await makeBundle(additionalFixtureSQL: splitFixtureSQL(parentID: "source-parent"))
        let database = try bundle.store.requireDatabase(for: "group-1")
        let selections = [
            identity("source-parent"),
            identity("source-parent-child-a", familyRootID: "source-parent", role: .child)
        ]
        let review = try await review(bundle, selections: selections)

        #expect(review.allocations.count == 3)
        #expect(review.groups.count == 1)
        #expect(review.groups[0].sourceTransactionIDs.count == 3)
        #expect(review.groups[0].duplicateTransactionIDs.count == 3)
        let receipt = try await database.commitTransactionDuplicate(review: review)
        let clones = try readCloneRows(review, bundle: bundle)

        #expect(clones.count == 3)
        #expect(Set(clones.map(\.id)) == Set(review.allocations.map(\.duplicateTransactionID)))
        #expect(clones.first(where: { $0.isParent == 1 })?.parentID == nil)
        #expect(clones.filter { $0.isChild == 1 }.allSatisfy {
            $0.parentID == review.allocations.first(where: { $0.sourceTransactionID == "source-parent" })?.duplicateTransactionID
        })
        #expect(receipt.changed.transactions.count == 6)
        let record = try #require(try await database.actionLogRecord(id: review.id))
        guard case .transactionDuplicate(let summary) = record.summary else {
            Issue.record("Expected duplicate History summary")
            return
        }
        #expect(summary.selectedSourceTransactionIDs == selections.map(\.transactionID))
        #expect(summary.duplicateTransactionIDs == review.allocations.map(\.duplicateTransactionID).sorted())
    }

    @Test func transferDuplicateReceiptIncludesBothAccountsAndRewritesPeerLink() async throws {
        let bundle = try await makeBundle(additionalFixtureSQL: """
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                 description, notes, cleared, transferred_id, isChild, reconciled)
            VALUES
                ('source-transfer', 'checking', 20260703, -1000, NULL, 0, NULL, 0,
                 'xfer-credit', 'transfer note', 0, 'source-transfer-peer', 0, 0),
                ('source-transfer-peer', 'credit', 20260703, 1000, NULL, 0, NULL, 0,
                 'xfer-checking', 'transfer note', 0, 'source-transfer', 0, 0);
            """)
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await review(bundle, selections: [identity("source-transfer")])
        let cloneBySource = Dictionary(uniqueKeysWithValues: review.allocations.map {
            ($0.sourceTransactionID, $0.duplicateTransactionID)
        })
        let sourceCloneID = try #require(cloneBySource["source-transfer"])
        let peerCloneID = try #require(cloneBySource["source-transfer-peer"])

        let receipt = try await database.commitTransactionDuplicate(review: review)

        #expect(receipt.changed.accounts == ["checking", "credit"])
        #expect(receipt.changed.months == ["2026-07"])
        #expect(receipt.changed.transactions.count == 4)
        #expect(try transactionState(sourceCloneID, bundle: bundle)?.transferID == peerCloneID)
        #expect(try transactionState(peerCloneID, bundle: bundle)?.transferID == sourceCloneID)
    }

    @Test(arguments: ["field", "link", "reconciliation", "tombstone"])
    func sourceMutationAfterReviewRejectsCommitWithoutPartialWrites(_ mutation: String) async throws {
        let bundle = try await makeBundle()
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await review(bundle, selections: [identity("txn")])
        let sql: String = switch mutation {
        case "field": "UPDATE transactions SET amount = -12346 WHERE id = 'txn';"
        case "link": "UPDATE transactions SET transferred_id = 'missing-peer' WHERE id = 'txn';"
        case "reconciliation": "UPDATE transactions SET reconciled = 1 WHERE id = 'txn';"
        default: "UPDATE transactions SET tombstone = 1 WHERE id = 'txn';"
        }
        try write(sql, bundle: bundle)
        let pendingBefore = try await database.pendingLocalSyncMessageCount()

        await #expect(throws: LocalFirstError.self) {
            try await database.commitTransactionDuplicate(review: review)
        }

        let cloneID = try #require(review.allocations.first?.duplicateTransactionID)
        #expect(try transactionState(cloneID, bundle: bundle) == nil)
        #expect(try await database.actionLogRecord(id: review.id) == nil)
        #expect(try await database.pendingLocalSyncMessageCount() == pendingBefore)
    }

    @Test func anyNonNullStoredSplitErrorBlocksReview() async throws {
        let bundle = try await makeBundle(additionalFixtureSQL: "UPDATE transactions SET error = 'split warning' WHERE id = 'txn';")
        let database = try bundle.store.requireDatabase(for: "group-1")

        await #expect(throws: LocalFirstError.self) {
            try await database.reviewTransactionDuplicate(
                context: context(bundle.store),
                selections: [identity("txn")]
            )
        }
    }

    @Test func nonreciprocalExternalTransferBacklinkBlocksReview() async throws {
        let bundle = try await makeBundle(additionalFixtureSQL: """
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                 description, notes, cleared, transferred_id, isChild, reconciled)
            VALUES ('external-backlink', 'credit', 20260703, 12345, 'groceries', 0,
                    NULL, 0, 'xfer-checking', NULL, 0, 'txn', 0, 0);
            """)
        let database = try bundle.store.requireDatabase(for: "group-1")

        await #expect(throws: LocalFirstError.self) {
            try await database.reviewTransactionDuplicate(
                context: context(bundle.store),
                selections: [identity("txn")]
            )
        }
    }

    @Test func rejectsGeneratedRootCloneIDCollisionOutsideTheSelectedGraph() async throws {
        let bundle = try await makeBundle(additionalFixtureSQL: collisionRowSQL("occupied-root-clone"))
        let database = try bundle.store.requireDatabase(for: "group-1")

        await #expect(throws: LocalFirstError.self) {
            try await database.reviewTransactionDuplicate(
                context: context(bundle.store),
                selections: [identity("txn")],
                cloneIDAtIndex: { _ in "occupied-root-clone" }
            )
        }
    }

    @Test func rejectsGeneratedSplitChildCloneIDCollisionOutsideTheSelectedGraph() async throws {
        let bundle = try await makeBundle(additionalFixtureSQL: splitFixtureSQL(parentID: "source-parent")
            + collisionRowSQL("occupied-child-clone"))
        let database = try bundle.store.requireDatabase(for: "group-1")

        await #expect(throws: LocalFirstError.self) {
            try await database.reviewTransactionDuplicate(
                context: context(bundle.store),
                selections: [identity("source-parent")],
                cloneIDAtIndex: { index in index == 1 ? "occupied-child-clone" : "fresh-\(index)" }
            )
        }
    }

    @Test func rejectsGeneratedTransferPeerCloneIDCollisionOutsideTheSelectedGraph() async throws {
        let bundle = try await makeBundle(additionalFixtureSQL: transferFixtureSQL
            + collisionRowSQL("occupied-peer-clone"))
        let database = try bundle.store.requireDatabase(for: "group-1")

        await #expect(throws: LocalFirstError.self) {
            try await database.reviewTransactionDuplicate(
                context: context(bundle.store),
                selections: [identity("source-transfer")],
                cloneIDAtIndex: { index in index == 1 ? "occupied-peer-clone" : "fresh-\(index)" }
            )
        }
    }

    @Test func commitRejectsCloneIDCollisionCreatedAfterReview() async throws {
        let bundle = try await makeBundle()
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await review(bundle, selections: [identity("txn")])
        let cloneID = try #require(review.allocations.first?.duplicateTransactionID)
        try write(collisionRowSQL(cloneID), bundle: bundle)
        let pendingBefore = try await database.pendingLocalSyncMessageCount()

        await #expect(throws: LocalFirstError.self) {
            try await database.commitTransactionDuplicate(review: review)
        }

        #expect(try transactionState(cloneID, bundle: bundle)?.amount == -50)
        #expect(try await database.actionLogRecord(id: review.id) == nil)
        #expect(try await database.pendingLocalSyncMessageCount() == pendingBefore)
    }

    @Test func changedPreallocatedCloneOrderIsRejectedBeforeAnyWrite() async throws {
        let bundle = try await makeBundle()
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await review(bundle, selections: [identity("txn")])
        let original = try #require(review.allocations.first)
        let changed = TransactionDuplicateAllocation(
            sourceTransactionID: original.sourceTransactionID,
            duplicateTransactionID: original.duplicateTransactionID,
            sortOrder: original.sortOrder + 0.25
        )
        let changedReview = TransactionDuplicateReview(
            id: review.id,
            context: review.context,
            selections: review.selections,
            groups: review.groups,
            allocations: [changed],
            affectedResources: review.affectedResources,
            reviewFingerprint: review.reviewFingerprint,
            canSubmit: review.canSubmit
        )

        await #expect(throws: LocalFirstError.self) {
            try await database.commitTransactionDuplicate(review: changedReview)
        }

        #expect(try transactionState(original.duplicateTransactionID, bundle: bundle) == nil)
        #expect(try await database.actionLogRecord(id: review.id) == nil)
    }

    @Test func missingRequiredGraphMetadataColumnBlocksReview() async throws {
        let bundle = try await makeBundle(additionalFixtureSQL: "ALTER TABLE transactions DROP COLUMN transferred_id;")
        let database = try bundle.store.requireDatabase(for: "group-1")

        await #expect(throws: LocalFirstError.self) {
            try await database.reviewTransactionDuplicate(
                context: context(bundle.store),
                selections: [identity("txn")]
            )
        }
    }

    @Test func cancelledDuplicateCommitIsRejectedBeforeTakingTheSessionGuard() async throws {
        let bundle = try await makeBundle()
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await review(bundle, selections: [identity("txn")])
        let pendingBefore = try await database.pendingLocalSyncMessageCount()
        let commit = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await database.commitTransactionDuplicate(review: review)
        }

        await #expect(throws: CancellationError.self) { try await commit.value }

        #expect(try await database.actionLogRecord(id: review.id) == nil)
        #expect(try await database.pendingLocalSyncMessageCount() == pendingBefore)
        #expect(try transactionState(review.allocations[0].duplicateTransactionID, bundle: bundle) == nil)
    }

    @Test func commitAfterSessionCloseIsRefusedWithoutWriting() async throws {
        let bundle = try await makeBundle()
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await review(bundle, selections: [identity("txn")])
        database.invalidateSessionWrites()
        let pendingCommit = Task {
            try await database.commitTransactionDuplicate(review: review)
        }

        await #expect(throws: LocalFirstError.budgetNotOpened) {
            try await pendingCommit.value
        }
        #expect(try await database.actionLogRecord(id: review.id) == nil)
        #expect(try transactionState(review.allocations[0].duplicateTransactionID, bundle: bundle) == nil)
    }

    @Test func sqliteApplyFailureRollsBackDuplicateRowsOutboxAndHistory() async throws {
        let bundle = try await makeBundle()
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await review(bundle, selections: [identity("txn")])
        let cloneID = try #require(review.allocations.first?.duplicateTransactionID)
        let pendingBefore = try await database.pendingLocalSyncMessageCount()
        try write("""
            CREATE TRIGGER reject_duplicate_apply BEFORE UPDATE ON transactions
            WHEN OLD.id = '\(cloneID)'
            BEGIN SELECT RAISE(ABORT, 'injected duplicate apply failure'); END;
            """, bundle: bundle)

        await #expect(throws: LocalFirstError.self) {
            try await database.commitTransactionDuplicate(review: review)
        }

        #expect(try transactionState(cloneID, bundle: bundle) == nil)
        #expect(try await database.actionLogRecord(id: review.id) == nil)
        #expect(try await database.pendingLocalSyncMessageCount() == pendingBefore)
    }

    @Test func actionLogInsertFailureRollsBackDuplicateRowsAndOutbox() async throws {
        let bundle = try await makeBundle()
        let database = try bundle.store.requireDatabase(for: "group-1")
        try await seedActionLog(database)
        let review = try await review(bundle, selections: [identity("txn")])
        let cloneID = try #require(review.allocations.first?.duplicateTransactionID)
        let pendingBefore = try await database.pendingLocalSyncMessageCount()
        try write("""
            CREATE TRIGGER reject_duplicate_history BEFORE INSERT ON actualist_action_log
            BEGIN SELECT RAISE(ABORT, 'injected duplicate History failure'); END;
            """, bundle: bundle)

        await #expect(throws: LocalFirstError.self) {
            try await database.commitTransactionDuplicate(review: review)
        }

        #expect(try transactionState(cloneID, bundle: bundle) == nil)
        #expect(try await database.actionLogRecord(id: review.id) == nil)
        #expect(try await database.recentBudgetActions().count == 1)
        #expect(try await database.pendingLocalSyncMessageCount() == pendingBefore)
    }

    @Test func undoRejectsAnyEditedCloneRow() async throws {
        let bundle = try await makeBundle()
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await review(bundle, selections: [identity("txn")])
        let cloneID = try #require(review.allocations.first?.duplicateTransactionID)
        _ = try await database.commitTransactionDuplicate(review: review)
        let record = try #require(try await database.actionLogRecord(id: review.id))
        try write("UPDATE transactions SET notes = 'edited after duplicate' WHERE id = '\(cloneID)';", bundle: bundle)

        let preview = try await database.actionUndoPreview(record: record)

        #expect(preview.block == .transactionCommandChanged)
        #expect(try transactionState(cloneID, bundle: bundle)?.notes == "edited after duplicate")
        #expect(try await database.actionLogRecord(id: review.id)?.status == .applied)
    }

    @Test func undoRejectsMembershipChangeToClonedSplitFamily() async throws {
        let bundle = try await makeBundle(additionalFixtureSQL: splitFixtureSQL(parentID: "source-parent"))
        let database = try bundle.store.requireDatabase(for: "group-1")
        let review = try await review(bundle, selections: [identity("source-parent")])
        let cloneParentID = try #require(review.allocations.first {
            $0.sourceTransactionID == "source-parent"
        }?.duplicateTransactionID)
        _ = try await database.commitTransactionDuplicate(review: review)
        let record = try #require(try await database.actionLogRecord(id: review.id))
        try write("""
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                 description, notes, cleared, transferred_id, isChild, reconciled)
            VALUES ('late-clone-child', 'checking', 20260703, -100, 'groceries', 0,
                    '\(cloneParentID)', 0, 'coffee', NULL, 0, NULL, 1, 0);
            """, bundle: bundle)

        let preview = try await database.actionUndoPreview(record: record)

        #expect(preview.block == .transactionCommandChanged)
        #expect(try transactionState(cloneParentID, bundle: bundle)?.tombstone == 0)
        #expect(try await database.actionLogRecord(id: review.id)?.status == .applied)
    }

    private func review(
        _ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle,
        selections: [TransactionSelectionIdentity]
    ) async throws -> TransactionDuplicateReview {
        try await bundle.store.reviewTransactionDuplicate(
            context: context(bundle.store),
            selections: selections
        )
    }

    private func context(_ store: LocalFirstActualStore) -> TransactionSelectionContext {
        TransactionSelectionContext(
            budgetID: "group-1",
            sessionGeneration: store.budgetSessionGeneration,
            scope: .spending,
            querySignature: TransactionFeedQuery().signature
        )
    }

    private func identity(
        _ id: String,
        familyRootID: String? = nil,
        role: TransactionSelectionIdentity.Role = .root
    ) -> TransactionSelectionIdentity {
        TransactionSelectionIdentity(
            transactionID: id,
            familyRootID: familyRootID ?? id,
            role: role
        )!
    }

    private func makeBundle(additionalFixtureSQL: String = "") async throws
        -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        try await support.makeOpenedWritableStoreBundle(additionalFixtureSQL: """
            ALTER TABLE transactions ADD COLUMN reconciled INTEGER;
            ALTER TABLE transactions ADD COLUMN sort_order REAL;
            ALTER TABLE transactions ADD COLUMN error TEXT;
            \(additionalFixtureSQL)
            """)
    }

    private func transactionState(
        _ id: String,
        bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle
    ) throws -> DuplicateStoredTransaction? {
        try readRows(bundle) { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, acct, date, amount, category, notes, cleared, reconciled, sort_order,
                       tombstone, parent_id, is_parent, isChild, transferred_id
                FROM transactions WHERE id = ?
                """, arguments: [id]) else { return nil }
            return DuplicateStoredTransaction(
                id: row["id"],
                accountID: row["acct"],
                dateValue: row["date"],
                amount: row["amount"],
                categoryID: row["category"],
                notes: row["notes"],
                cleared: row["cleared"],
                reconciled: row["reconciled"],
                sortOrder: row["sort_order"],
                tombstone: row["tombstone"],
                parentID: row["parent_id"],
                isParent: row["is_parent"],
                isChild: row["isChild"],
                transferID: row["transferred_id"]
            )
        }
    }

    private func readCloneRows(
        _ review: TransactionDuplicateReview,
        bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle
    ) throws -> [DuplicateStoredTransaction] {
        let cloneIDs = review.allocations.map(\.duplicateTransactionID)
        let placeholders = Array(repeating: "?", count: cloneIDs.count).joined(separator: ",")
        return try readRows(bundle) { db in
            try Row.fetchAll(db, sql: """
                SELECT id, acct, date, amount, category, notes, cleared, reconciled, sort_order,
                       tombstone, parent_id, is_parent, isChild, transferred_id
                FROM transactions WHERE id IN (\(placeholders)) ORDER BY id
                """, arguments: StatementArguments(cloneIDs)).map { row in
                DuplicateStoredTransaction(
                    id: row["id"],
                    accountID: row["acct"],
                    dateValue: row["date"],
                    amount: row["amount"],
                    categoryID: row["category"],
                    notes: row["notes"],
                    cleared: row["cleared"],
                    reconciled: row["reconciled"],
                    sortOrder: row["sort_order"],
                    tombstone: row["tombstone"],
                    parentID: row["parent_id"],
                    isParent: row["is_parent"],
                    isChild: row["isChild"],
                    transferID: row["transferred_id"]
                )
            }
        }
    }

    private func write(
        _ sql: String,
        bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle
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

    private func seedActionLog(_ database: BudgetDatabase) async throws {
        var builder = LocalFirstSyncMessageBuilder()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try support.makeDate(year: 2026, month: 7, day: 3),
            amountMinorUnits: -100,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let messages = try await database.createSimpleTransactionMessages(
            draft,
            transactionID: "history-seed",
            payeeID: "coffee",
            builder: &builder
        )
        _ = try await database.commitUserAction(
            messages,
            descriptor: .createTransaction(CreateTransactionDescriptor(
                month: "2026-07",
                amount: -100,
                payeeName: "Coffee Shop",
                categoryID: "groceries",
                primaryTransactionID: "history-seed",
                transactionIDs: ["history-seed"],
                graph: .simple,
                createdPayeeID: nil
            )),
            source: .ui,
            actionID: "history-seed-action"
        )
    }

    private func splitFixtureSQL(parentID: String) -> String {
        """
        INSERT INTO transactions
            (id, acct, date, amount, category, tombstone, parent_id, is_parent,
             description, notes, cleared, transferred_id, isChild, reconciled)
        VALUES
            ('\(parentID)', 'checking', 20260703, -1000, NULL, 0, NULL, 1,
             'coffee', 'parent note', 0, NULL, 0, 0),
            ('\(parentID)-child-a', 'checking', 20260703, -400, 'groceries', 0, '\(parentID)', 0,
             'coffee', NULL, 0, NULL, 1, 0),
            ('\(parentID)-child-b', 'checking', 20260703, -600, 'utilities', 0, '\(parentID)', 0,
             'coffee', NULL, 0, NULL, 1, 0);
        """
    }

    private var transferFixtureSQL: String {
        """
        INSERT INTO transactions
            (id, acct, date, amount, category, tombstone, parent_id, is_parent,
             description, notes, cleared, transferred_id, isChild, reconciled)
        VALUES
            ('source-transfer', 'checking', 20260703, -1000, NULL, 0, NULL, 0,
             'xfer-credit', 'transfer note', 0, 'source-transfer-peer', 0, 0),
            ('source-transfer-peer', 'credit', 20260703, 1000, NULL, 0, NULL, 0,
             'xfer-checking', 'transfer note', 0, 'source-transfer', 0, 0);
        """
    }

    private func collisionRowSQL(_ id: String) -> String {
        """
        INSERT INTO transactions
            (id, acct, date, amount, category, tombstone, parent_id, is_parent,
             description, notes, cleared, transferred_id, isChild, reconciled)
        VALUES ('\(id)', 'checking', 20260703, -50, 'groceries', 0, NULL, 0,
                'coffee', NULL, 0, NULL, 0, 0);
        """
    }
}

private struct DuplicateStoredTransaction: Equatable {
    let id: String
    let accountID: String?
    let dateValue: Int?
    let amount: Int?
    let categoryID: String?
    let notes: String?
    let cleared: Int?
    let reconciled: Int?
    let sortOrder: Double?
    let tombstone: Int?
    let parentID: String?
    let isParent: Int?
    let isChild: Int?
    let transferID: String?
}
