import Foundation
import GRDB
import Testing
@testable import Actualist

/// The Budget screen's alerts read the uncategorized count from SQLite
/// (`fetchUncategorizedTransactionCount`), not from an in-memory transaction list.
extension LocalFirstActualStoreTests {
    private func uncategorizedCount(extraSQL: String) async throws -> Int {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions ADD COLUMN description TEXT;
            CREATE TABLE payees (
                id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER
            );
            INSERT INTO accounts VALUES ('savings', 'Savings', 1, 0, 0, 2);
            UPDATE transactions SET category = 'groceries' WHERE id = 'txn';
            \(extraSQL)
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        return try await database.fetchUncategorizedTransactionCount()
    }

    @Test func uncategorizedCountIncludesOnlyReviewableTransactions() async throws {
        let count = try await uncategorizedCount(extraSQL: """
            INSERT INTO payees VALUES ('on-budget-xfer', 'Transfer', 'checking', 0);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, description) VALUES
                ('needs-category', 'checking', 20260703, -100, NULL, 0, NULL, 0, NULL),
                ('also-needs', 'checking', 20260703, -100, '', 0, NULL, 0, NULL),
                ('categorized', 'checking', 20260703, -100, 'groceries', 0, NULL, 0, NULL),
                ('transfer', 'checking', 20260703, -100, NULL, 0, NULL, 0, 'on-budget-xfer'),
                ('deleted', 'checking', 20260703, -100, NULL, 1, NULL, 0, NULL),
                ('split-parent', 'checking', 20260703, -300, NULL, 0, NULL, 1, NULL),
                ('split-child', 'checking', 20260703, -300, NULL, 0, 'split-parent', 0, NULL),
                ('other-month', 'checking', 20260630, -100, NULL, 0, NULL, 0, NULL),
                ('split-whole', 'checking', 20260703, -300, NULL, 0, NULL, 1, NULL),
                ('whole-child', 'checking', 20260703, -300, 'groceries', 0, 'split-whole', 0, NULL);
            """)

        #expect(count == 4)
    }

    @Test func uncategorizedCountIsZeroWhenEverythingIsCategorized() async throws {
        #expect(try await uncategorizedCount(extraSQL: "") == 0)
    }

    @Test func uncategorizedCountIncludesTransfersToOffBudgetAccounts() async throws {
        let count = try await uncategorizedCount(extraSQL: """
            INSERT INTO payees VALUES ('off-budget-xfer', 'To Savings', 'savings', 0);
            INSERT INTO payees VALUES ('on-budget-xfer', 'To Checking', 'checking', 0);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, description) VALUES
                ('off-budget-transfer', 'checking', 20260703, -100, NULL, 0, NULL, 0, 'off-budget-xfer'),
                ('on-budget-transfer', 'checking', 20260703, -100, NULL, 0, NULL, 0, 'on-budget-xfer');
            """)

        #expect(count == 1)
    }

    @Test func uncategorizedCountExcludesTransactionsInsideOffBudgetAccounts() async throws {
        let count = try await uncategorizedCount(extraSQL: """
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent) VALUES
                ('tracking-adjustment', 'savings', 20260703, -100, NULL, 0, NULL, 0),
                ('checking-purchase', 'checking', 20260703, -100, NULL, 0, NULL, 0);
            """)

        #expect(count == 1)
    }

    @Test func budgetAlertSnapshotIsOrderedToBudgetThenOverspendingThenUncategorized() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO transactions VALUES ('needs-category', 'checking', 20260703, -100, NULL, 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let month = makeBudgetMonth(
            toBudget: 1500,
            groups: [
                makeGroup(id: "everyday", isIncome: false, categories: [
                    makeCategory(id: "groceries", balance: -2000)
                ])
            ]
        )

        let alerts = try await makeStore().budgetAlertSnapshot(
            database: database,
            month: month,
            isTrackingBudget: false
        )

        #expect(alerts.map(\.kind) == ["toBudget", "overspending", "uncategorizedTransactions"])
    }
}
