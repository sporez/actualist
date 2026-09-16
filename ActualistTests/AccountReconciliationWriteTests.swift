import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct AccountReconciliationWriteTests {
    private let support = LocalFirstActualStoreTests()

    @Test func sharedRuleProjectionAppliesEveryAdjustmentField() throws {
        let baseDate = try support.makeDate(year: 2026, month: 9, day: 14)
        let ruleDate = try support.makeDate(year: 2026, month: 9, day: 1)
        let draft = TransactionDraft(
            accountID: "checking",
            date: baseDate,
            amountMinorUnits: 2_500,
            payeeID: nil,
            payeeName: "",
            categoryID: nil,
            notes: "Reconciliation balance adjustment",
            cleared: true,
            isTransfer: false
        )

        let projected = TransactionRulePreviewProjection.applying(
            TransactionRulePreview(
                categoryID: "groceries",
                notes: "Rule changed",
                accountID: "savings",
                payeeID: "bank",
                amountMinorUnits: 1_700,
                date: ruleDate,
                cleared: false,
                scheduleID: "schedule-1"
            ),
            to: draft
        )

        #expect(projected.accountID == "savings")
        #expect(projected.date == ruleDate)
        #expect(projected.amountMinorUnits == 1_700)
        #expect(projected.payeeID == "bank")
        #expect(projected.categoryID == "groceries")
        #expect(projected.notes == "Rule changed")
        #expect(!projected.cleared)
        #expect(projected.scheduleID == "schedule-1")
    }

    @Test func previewWithoutMatchingRuleKeepsDefaultAdjustmentNotes() async throws {
        let bundle = try makeDatabase()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try support.makeDate(year: 2026, month: 9, day: 14),
            amountMinorUnits: 2_500,
            payeeID: nil,
            payeeName: "",
            categoryID: nil,
            notes: "Reconciliation balance adjustment",
            cleared: true,
            isTransfer: false
        )

        let preview = try await bundle.database.previewRules(for: draft)
        let projected = TransactionRulePreviewProjection.applying(preview, to: draft)
        let restored = projected.notes == nil && preview.notes == nil
            ? projected.withNotes(draft.notes)
            : projected

        #expect(preview.notes == "Reconciliation balance adjustment")
        #expect(restored.notes == "Reconciliation balance adjustment")
    }

    @Test func adjustmentUsesFreshDifferenceFixedDateNullPayeeAndHistory() async throws {
        let bundle = try makeDatabase()
        let now = try support.makeDate(year: 2026, month: 9, day: 14)

        let write = try await bundle.database.createReconciliationAdjustment(
            accountID: "checking",
            targetBalance: 2_500,
            now: now,
            transactionID: "adjustment"
        )

        let row: Row? = try bundle.queue.readSync { db in
            try Row.fetchOne(db, sql: "SELECT * FROM transactions WHERE id = 'adjustment'")
        }
        let actionCount: Int = try await bundle.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actualist_action_log") ?? 0
        }
        let outboxCount: Int = try await bundle.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actualist_outbox") ?? 0
        }

        #expect(write.committed)
        #expect(write.changed.accounts == ["checking"])
        #expect(write.changed.months == ["2026-09"])
        #expect(write.changed.transactions == ["adjustment"])
        #expect(row?["acct"] as String? == "checking")
        #expect(row?["date"] as Int? == 20_260_914)
        #expect(row?["amount"] as Int? == 2_500)
        #expect(row?["description"] as String? == nil)
        #expect(row?["category"] as String? == nil)
        #expect(row?["notes"] as String? == "Reconciliation balance adjustment")
        let fetched = try await bundle.database.fetchTransactions(accountID: "checking")
        #expect(fetched.first { $0.id == "adjustment" }?.notes == "Reconciliation balance adjustment")
        #expect(row?["cleared"] as Int? == 1)
        #expect(row?["reconciled"] as Int? == 0)
        #expect(actionCount == 1)
        #expect(outboxCount > 0)
    }

    @Test func adjustmentKeepsDefaultNotesWhenRuleClearsThem() async throws {
        let bundle = try makeDatabase(extraSQL: """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'clear-notes',
                '[{"field":"notes","op":"is","value":"Reconciliation balance adjustment"}]',
                '[{"field":"notes","op":"set","value":""}]',
                0
            );
            """)

        _ = try await bundle.database.createReconciliationAdjustment(
            accountID: "checking",
            targetBalance: 2_500,
            now: try support.makeDate(year: 2026, month: 9, day: 14),
            transactionID: "cleared-notes"
        )

        let fetched = try await bundle.database.fetchTransactions(accountID: "checking")
        #expect(fetched.first { $0.id == "cleared-notes" }?.notes == "Reconciliation balance adjustment")
    }

    @Test func ruleDeletedAdjustmentWritesNothingAndCreatesNoHistory() async throws {
        let bundle = try makeDatabase(extraSQL: """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'delete-adjustment',
                '[{"field":"notes","op":"is","value":"Reconciliation balance adjustment"}]',
                '[{"op":"delete-transaction","value":""}]',
                0
            );
            """)
        let beforeMessageCount = try await messageCount(bundle.queue)

        let write = try await bundle.database.createReconciliationAdjustment(
            accountID: "checking",
            targetBalance: 2_500,
            now: Date(timeIntervalSince1970: 1_789_344_000),
            transactionID: "deleted-adjustment"
        )

        let afterMessageCount = try await messageCount(bundle.queue)
        let transactionCount: Int = try await bundle.queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transactions WHERE id = 'deleted-adjustment'"
            ) ?? 0
        }
        let actionLogExists: Bool = try await bundle.queue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = 'actualist_action_log')"
            ) ?? false
        }

        #expect(!write.committed)
        #expect(write.changed.transactions.isEmpty)
        #expect(transactionCount == 0)
        #expect(afterMessageCount == beforeMessageCount)
        #expect(!actionLogExists)
    }

    @Test func adjustmentPersistsRuleGeneratedSplitThroughSharedFamilyWriter() async throws {
        let bundle = try makeDatabase(extraSQL: """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'split-adjustment',
                '[{"field":"notes","op":"is","value":"Reconciliation balance adjustment"}]',
                '[{"op":"set-split-amount","value":1000,"options":{"method":"fixed-amount","splitIndex":1}},{"op":"set","field":"category","value":"groceries","options":{"splitIndex":1}},{"op":"set-split-amount","value":0,"options":{"method":"remainder","splitIndex":2}},{"op":"set","field":"category","value":"groceries","options":{"splitIndex":2}}]',
                0
            );
            """)

        let write = try await bundle.database.createReconciliationAdjustment(
            accountID: "checking",
            targetBalance: 3_000,
            now: try support.makeDate(year: 2026, month: 9, day: 14),
            transactionID: "split-adjustment"
        )

        let rows: [Row] = try bundle.queue.readSync { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, amount, parent_id, is_parent, cleared, reconciled
                    FROM transactions
                    WHERE id = 'split-adjustment' OR parent_id = 'split-adjustment'
                    ORDER BY amount
                    """
            )
        }
        let parent = try #require(rows.first { ($0["id"] as String?) == "split-adjustment" })
        let children = rows.filter { ($0["parent_id"] as String?) == "split-adjustment" }

        #expect(write.committed)
        #expect(parent["amount"] as Int? == 3_000)
        #expect(parent["is_parent"] as Int? == 1)
        #expect(parent["cleared"] as Int? == 1)
        #expect(parent["reconciled"] as Int? == 0)
        #expect(children.compactMap { $0["amount"] as Int? } == [1_000, 2_000])
        #expect(children.allSatisfy { ($0["cleared"] as Int?) == 1 })
    }

    @Test func adjustmentRuleTransferCreatesPairedLeg() async throws {
        let bundle = try makeDatabase(extraSQL: """
            INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0, 2, NULL);
            CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER);
            INSERT INTO payees VALUES ('to-savings', '', 'savings', 0);
            INSERT INTO payees VALUES ('to-checking', '', 'checking', 0);
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'transfer-adjustment',
                '[{"field":"notes","op":"is","value":"Reconciliation balance adjustment"}]',
                '[{"op":"set","field":"payee","value":"to-savings"}]',
                0
            );
            """)

        let write = try await bundle.database.createReconciliationAdjustment(
            accountID: "checking",
            targetBalance: 3_000,
            now: try support.makeDate(year: 2026, month: 9, day: 14),
            transactionID: "transfer-adjustment"
        )

        let rows: [Row] = try bundle.queue.readSync { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, acct, amount, description, transferred_id, cleared
                    FROM transactions
                    WHERE id = 'transfer-adjustment' OR transferred_id = 'transfer-adjustment'
                    ORDER BY acct
                    """
            )
        }
        let source = try #require(rows.first { ($0["id"] as String?) == "transfer-adjustment" })
        let paired = try #require(rows.first { ($0["id"] as String?) != "transfer-adjustment" })

        #expect(Set(write.changed.accounts) == ["checking", "savings"])
        #expect(write.changed.transactions.count == 2)
        #expect(source["acct"] as String? == "checking")
        #expect(source["amount"] as Int? == 3_000)
        #expect(source["description"] as String? == "to-savings")
        #expect(source["cleared"] as Int? == 1)
        #expect(paired["acct"] as String? == "savings")
        #expect(paired["amount"] as Int? == -3_000)
        #expect(paired["description"] as String? == "to-checking")
        #expect(paired["cleared"] as Int? == 0)
    }

    @Test func finishLocksEveryClearedFamilyRowAndStoresMilliseconds() async throws {
        let bundle = try makeDatabase()
        try await insertSplitFamily(in: bundle.queue, reconciled: false)
        let now = Date(timeIntervalSince1970: 1_789_344_000.123)
        let snapshot = try await bundle.database.accountReconciliationSnapshot(accountID: "checking")

        let write = try await bundle.database.finishReconciliation(
            accountID: "checking",
            targetBalance: snapshot.clearedBalance,
            now: now
        )

        let reconciled: [Row] = try bundle.queue.readSync { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, IFNULL(reconciled, 0) AS reconciled FROM transactions WHERE id IN ('txn', 'split', 'split-a', 'split-b')"
            )
        }
        let timestamp: String? = try await bundle.queue.read { db in
            try String.fetchOne(db, sql: "SELECT last_reconciled FROM accounts WHERE id = 'checking'")
        }

        #expect(write.committed)
        #expect(Set(write.changed.transactions) == ["split", "split-a", "split-b"])
        #expect(reconciled.first { ($0["id"] as String?) == "txn" }?["reconciled"] as Int? == 0)
        #expect(reconciled.filter { ($0["id"] as String?) != "txn" }.allSatisfy {
            ($0["reconciled"] as Int?) == 1
        })
        #expect(timestamp == "1789344000123")
    }

    @Test func nonzeroFinishDoesNotWriteAndExitOnlyStoresTimestamp() async throws {
        let bundle = try makeDatabase()
        try await bundle.queue.write { db in
            try db.execute(sql: "UPDATE transactions SET cleared = 1 WHERE id = 'txn'")
        }
        let beforeMessageCount = try await messageCount(bundle.queue)

        await #expect(throws: AccountReconciliationCommandError.balanceChanged) {
            try await bundle.database.finishReconciliation(
                accountID: "checking",
                targetBalance: 0,
                now: Date(timeIntervalSince1970: 1_789_344_000)
            )
        }
        let afterFailedFinishMessageCount = try await messageCount(bundle.queue)
        #expect(afterFailedFinishMessageCount == beforeMessageCount)

        _ = try await bundle.database.exitReconciliation(
            accountID: "checking",
            now: Date(timeIntervalSince1970: 1_789_344_001.456)
        )
        let values: (String?, Int?) = try await bundle.queue.read { db in
            (
                try String.fetchOne(db, sql: "SELECT last_reconciled FROM accounts WHERE id = 'checking'"),
                try Int.fetchOne(db, sql: "SELECT IFNULL(reconciled, 0) FROM transactions WHERE id = 'txn'")
            )
        }
        #expect(values.0 == "1789344001456")
        #expect(values.1 == 0)
    }

    @Test func unlockExpandsToFamilyPreservesClearedAndDoesNotTouchTransferPair() async throws {
        let bundle = try makeDatabase()
        try await insertSplitFamily(in: bundle.queue, reconciled: true)
        try await bundle.queue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions
                    (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                     description, notes, cleared, isChild, reconciled, transferred_id)
                VALUES ('paired', 'savings', 20260902, -3000, NULL, 0, NULL, 0,
                        NULL, NULL, 1, 0, 1, 'split-a')
                """)
            try db.execute(
                sql: "UPDATE transactions SET transferred_id = 'paired' WHERE id = 'split-a'"
            )
        }

        let write = try await bundle.database.unlockReconciledTransaction(
            accountID: "checking",
            transactionID: "split-a",
            now: Date(timeIntervalSince1970: 1_789_344_000)
        )

        let rows: [Row] = try bundle.queue.readSync { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, cleared, reconciled FROM transactions WHERE id IN ('split', 'split-a', 'split-b', 'paired')"
            )
        }
        #expect(Set(write.changed.transactions) == ["split", "split-a", "split-b"])
        let familyRows = rows.filter { ($0["id"] as String?) != "paired" }
        let familyPreservedCleared = familyRows.allSatisfy { row in
            let cleared = row["cleared"] as Int?
            let reconciled = row["reconciled"] as Int?
            return cleared == 1 && reconciled == 0
        }
        #expect(familyPreservedCleared)
        #expect(rows.first { ($0["id"] as String?) == "paired" }?["reconciled"] as Int? == 1)
    }

    @Test func finishRollsBackTimestampAndLocksWhenOutboxCommitCannotStart() async throws {
        let bundle = try makeDatabase()
        try await bundle.queue.write { db in
            try db.execute(sql: "UPDATE transactions SET cleared = 1 WHERE id = 'txn'")
            try db.execute(sql: "DROP TABLE messages_crdt")
        }
        let snapshot = try await bundle.database.accountReconciliationSnapshot(accountID: "checking")

        await #expect(throws: LocalFirstError.self) {
            try await bundle.database.finishReconciliation(
                accountID: "checking",
                targetBalance: snapshot.clearedBalance,
                now: Date(timeIntervalSince1970: 1_789_344_000)
            )
        }

        let values: (String?, Int?) = try await bundle.queue.read { db in
            (
                try String.fetchOne(db, sql: "SELECT last_reconciled FROM accounts WHERE id = 'checking'"),
                try Int.fetchOne(db, sql: "SELECT IFNULL(reconciled, 0) FROM transactions WHERE id = 'txn'")
            )
        }
        #expect(values.0 == nil)
        #expect(values.1 == 0)
    }

    @Test func storeAdjustmentRefreshesFeedAndReturnsFreshSnapshot() async throws {
        let store = try await support.makeOpenedWritableStore(additionalFixtureSQL: """
            ALTER TABLE accounts ADD COLUMN last_reconciled TEXT;
            """)

        let result = try await store.createReconciliationAdjustmentAndRefresh(
            budgetID: "group-1",
            accountID: "checking",
            targetBalance: 1_000
        )

        let transactionID = try #require(result.changed.transactions.first)
        let loaded = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")
        )
        let adjustment = try #require(loaded.transactions.first { $0.id == transactionID })
        #expect(adjustment.amount == 1_000)
        #expect(adjustment.payee == nil)
        #expect(adjustment.category == nil)
        #expect(adjustment.cleared == .bool(true))
        #expect(result.snapshot.clearedBalance == 1_000)
    }

    private struct DatabaseBundle {
        let database: BudgetDatabase
        let queue: DatabaseQueue
    }

    private func makeDatabase(extraSQL: String = "") throws -> DatabaseBundle {
        let url = try support.makeSQLiteFixture(extraSQL: """
            ALTER TABLE accounts ADD COLUMN last_reconciled TEXT;
            ALTER TABLE transactions ADD COLUMN description TEXT;
            ALTER TABLE transactions ADD COLUMN notes TEXT;
            ALTER TABLE transactions ADD COLUMN cleared INTEGER DEFAULT 0;
            ALTER TABLE transactions ADD COLUMN isChild INTEGER DEFAULT 0;
            ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
            \(extraSQL)
            """)
        return DatabaseBundle(
            database: try BudgetDatabase(databaseURL: url, localNodeID: "node1"),
            queue: try DatabaseQueue(path: url.path)
        )
    }

    private func messageCount(_ queue: DatabaseQueue) async throws -> Int {
        try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0
        }
    }

    private func insertSplitFamily(in queue: DatabaseQueue, reconciled: Bool) async throws {
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions
                    (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                     description, notes, cleared, isChild, reconciled)
                VALUES
                    ('split', 'checking', 20260901, 3000, NULL, 0, NULL, 1,
                     NULL, NULL, 1, 0, ?),
                    ('split-a', 'checking', 20260901, 1000, 'groceries', 0, 'split', 0,
                     NULL, NULL, 1, 1, ?),
                    ('split-b', 'checking', 20260901, 2000, 'groceries', 0, 'split', 0,
                     NULL, NULL, 1, 1, ?)
                """, arguments: [reconciled, reconciled, reconciled])
        }
    }
}
