import GRDB
import Testing
@testable import Actualist

@MainActor
struct AccountReconciliationReadTests {
    private let support = LocalFirstActualStoreTests()

    @Test func snapshotCountsClearedRootAmountsOnceAndIncludesReconciledRows() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            ALTER TABLE accounts ADD COLUMN balance_current;
            ALTER TABLE accounts ADD COLUMN last_reconciled TEXT;
            UPDATE accounts
                SET balance_current = '20450', last_reconciled = '1770000000123'
                WHERE id = 'checking';
            ALTER TABLE transactions ADD COLUMN cleared INTEGER DEFAULT 0;
            ALTER TABLE transactions ADD COLUMN reconciled INTEGER DEFAULT 0;
            UPDATE transactions SET cleared = 1, reconciled = 1 WHERE id = 'txn';
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent, cleared, reconciled)
                VALUES ('uncleared', 'checking', 20260704, 1000, 'groceries', 0, NULL, 0, 0, 0);
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent, cleared, reconciled)
                VALUES ('split', 'checking', 20260705, -5000, NULL, 0, NULL, 1, 1, 0);
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent, cleared, reconciled)
                VALUES ('split-a', 'checking', 20260705, -2000, 'groceries', 0, 'split', 0, 1, 0);
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent, cleared, reconciled)
                VALUES ('split-b', 'checking', 20260705, -3000, 'groceries', 0, 'split', 0, 1, 0);
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent, cleared, reconciled)
                VALUES ('dead', 'checking', 20260706, 9000, 'groceries', 1, NULL, 0, 1, 0);
            """))

        let snapshot = try await database.accountReconciliationSnapshot(accountID: "checking")

        #expect(snapshot.capability == .available)
        #expect(snapshot.accountName == "Checking")
        #expect(snapshot.workingBalance == -16_345)
        #expect(snapshot.clearedBalance == -17_345)
        #expect(snapshot.lastSyncedBalance == 20_450)
        #expect(snapshot.lastReconciledMilliseconds == 1_770_000_000_123)
    }

    @Test func snapshotAllowsClosedOffBudgetAccountAndOptionalSyncedBalance() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            ALTER TABLE accounts ADD COLUMN last_reconciled TEXT;
            UPDATE accounts SET closed = 1, offbudget = 1 WHERE id = 'checking';
            ALTER TABLE transactions ADD COLUMN cleared INTEGER DEFAULT 0;
            ALTER TABLE transactions ADD COLUMN reconciled INTEGER DEFAULT 0;
            """))

        let snapshot = try await database.accountReconciliationSnapshot(accountID: "checking")

        #expect(snapshot.capability == .available)
        #expect(snapshot.lastSyncedBalance == nil)
        #expect(snapshot.lastReconciledMilliseconds == nil)
    }

    @Test func snapshotFailsClosedWithoutObservedLastReconciledMigration() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions ADD COLUMN cleared INTEGER DEFAULT 0;
            ALTER TABLE transactions ADD COLUMN reconciled INTEGER DEFAULT 0;
            """))

        let snapshot = try await database.accountReconciliationSnapshot(accountID: "checking")

        #expect(snapshot.capability == .unavailable(.missingLastReconciledColumn))
        #expect(snapshot.accountName == "Checking")
    }

    @Test func snapshotFailsClosedForMissingTransactionColumnsAndAccount() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            ALTER TABLE accounts ADD COLUMN last_reconciled TEXT;
            """))

        let missingColumns = try await database.accountReconciliationSnapshot(accountID: "checking")
        let missingAccount = try await database.accountReconciliationSnapshot(accountID: "missing")

        #expect(missingColumns.capability == .unavailable(.missingTransactionSchema))
        #expect(missingAccount.capability == .unavailable(.accountNotFound))
    }

    @Test func storeRequiresMatchingOpenBudgetAndReturnsDatabaseSnapshot() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            ALTER TABLE accounts ADD COLUMN last_reconciled TEXT;
            ALTER TABLE transactions ADD COLUMN cleared INTEGER DEFAULT 0;
            ALTER TABLE transactions ADD COLUMN reconciled INTEGER DEFAULT 0;
            """))
        let store = support.makeStore()
        store.openedBudgetID = "budget"
        store.database = database

        let snapshot = try await store.accountReconciliationSnapshot(
            budgetID: "budget",
            accountID: "checking"
        )
        #expect(snapshot.capability == .available)

        await #expect(throws: LocalFirstError.budgetNotOpened) {
            try await store.accountReconciliationSnapshot(
                budgetID: "different",
                accountID: "checking"
            )
        }
    }
}
