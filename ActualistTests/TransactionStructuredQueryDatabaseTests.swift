import Foundation
import GRDB
import Testing
@testable import Actualist

struct TransactionStructuredQueryDatabaseTests {
    @Test func andQueryUsesMappedIDsAndAttachesUnmatchedSplitContext() async throws {
        let database = try database()
        let query = TransactionFeedQuery(
            conditionsJoin: .and,
            conditions: [
                .category(.equals("groceries")),
                .payee(.equals("market")),
            ]
        )

        let page = try await database.fetchTransactionQueryPage(scope: .spending, query: query)

        #expect(page.transactions.map(\.id) == ["split-parent"])
        #expect(page.transactions.first?.subtransactions.map(\.id) == ["split-match", "split-context"])
        #expect(page.totalMatchCount == 1)
        #expect(page.matchingTransactionIDs == ["split-match"])
        #expect(page.contributingTransactionIDs == ["split-match"])
        #expect(page.attachedContextTransactionIDs == ["split-parent", "split-context"])
        #expect(page.querySignature == query.signature)
    }

    @Test func orQueryPagesFamiliesAndReportsAnExactRootTotal() async throws {
        let database = try database()
        let query = TransactionFeedQuery(
            conditionsJoin: .or,
            conditions: [
                .category(.equals("utilities")),
                .account(.equals("savings")),
            ]
        )

        let first = try await database.fetchTransactionQueryPage(
            scope: .spending,
            query: query,
            limit: 1,
            offset: 0
        )
        let second = try await database.fetchTransactionQueryPage(
            scope: .spending,
            query: query,
            limit: 1,
            offset: first.nextOffset
        )

        #expect(first.transactions.map(\.id) == ["split-parent"])
        #expect(first.totalMatchCount == 2)
        #expect(!first.reachedEnd)
        #expect(first.nextOffset == 1)
        #expect(first.matchingTransactionIDs == ["split-context"])
        #expect(second.transactions.map(\.id) == ["savings-row"])
        #expect(second.totalMatchCount == 2)
        #expect(second.reachedEnd)
        #expect(second.nextOffset == 2)
    }

    @Test func dateAndAccountHappyPathMarksTheWholeDisplayedFamilyAsMatching() async throws {
        let database = try database()
        let day = try #require(TransactionQueryDay(rawValue: "2026-09-09"))
        let query = TransactionFeedQuery(
            conditionsJoin: .and,
            conditions: [
                .date(TransactionQueryDateCondition(operation: .isApproximately, day: day)),
                .account(.equals("checking")),
            ]
        )

        let page = try await database.fetchTransactionQueryPage(scope: .spending, query: query)

        #expect(page.transactions.map(\.id) == ["checking-new", "split-parent"])
        #expect(page.totalMatchCount == 2)
        #expect(page.matchingTransactionIDs == [
            "checking-new", "split-parent", "split-match", "split-context",
        ])
        #expect(page.contributingTransactionIDs == ["checking-new", "split-match", "split-context"])
        #expect(page.attachedContextTransactionIDs.isEmpty)
    }

    @Test func textQueryCountsPhysicalRowsAndOnlyAttachesChildrenToAMatchingParent() async throws {
        let database = try database()
        let childQuery = TransactionFeedQuery(text: "child needle")
        let parentQuery = TransactionFeedQuery(text: "parent needle")

        let child = try await database.fetchTransactionQueryPage(scope: .spending, query: childQuery)
        let parent = try await database.fetchTransactionQueryPage(scope: .spending, query: parentQuery)

        #expect(child.transactions.map(\.id) == ["split-match"])
        #expect(child.totalMatchCount == 1)
        #expect(child.matchingTransactionIDs == ["split-match"])
        #expect(child.attachedContextTransactionIDs.isEmpty)
        #expect(parent.transactions.map(\.id) == ["split-parent"])
        #expect(parent.totalMatchCount == 1)
        #expect(parent.matchingTransactionIDs == ["split-parent"])
        #expect(parent.attachedContextTransactionIDs == ["split-match", "split-context"])
        #expect(parent.contributingTransactionIDs.isEmpty)
    }

    @Test func drilldownReturnsUnpagedContributorsWithoutCountingContext() async throws {
        let database = try database()
        let query = TransactionFeedQuery(conditions: [.category(.equals("groceries"))])

        let result = try await database.fetchTransactionDrilldown(
            TransactionDrilldownRequest(scope: .spending, query: query)
        )

        #expect(result.displayTransactions.map(\.id) == ["checking-new", "split-parent"])
        #expect(result.totalMatchCount == 2)
        #expect(result.matchingTransactionIDs == ["checking-new", "split-match"])
        #expect(result.contributingTransactions.map(\.id) == ["checking-new", "split-match"])
        #expect(result.attachedContextTransactionIDs == ["split-parent", "split-context"])
        #expect(result.querySignature == query.signature)
    }

    private func database() throws -> BudgetDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ActualistStructuredQuery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "db.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, offbudget INTEGER,
                    closed INTEGER, tombstone INTEGER, sort_order INTEGER
                );
                CREATE TABLE category_groups (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, is_income INTEGER,
                    hidden INTEGER, tombstone INTEGER, sort_order INTEGER
                );
                CREATE TABLE categories (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, cat_group TEXT,
                    is_income INTEGER, hidden INTEGER, tombstone INTEGER, sort_order INTEGER
                );
                CREATE TABLE category_mapping (id TEXT PRIMARY KEY, transferId TEXT);
                CREATE TABLE payees (
                    id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER
                );
                CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT);
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY, isParent INTEGER DEFAULT 0, isChild INTEGER DEFAULT 0,
                    acct TEXT, category TEXT, amount INTEGER, description TEXT, notes TEXT,
                    date INTEGER, sort_order REAL, tombstone INTEGER DEFAULT 0,
                    parent_id TEXT, starting_balance_flag INTEGER DEFAULT 0,
                    cleared INTEGER DEFAULT 0, reconciled INTEGER DEFAULT 0
                );

                INSERT INTO accounts VALUES
                    ('checking', 'Checking', 0, 0, 0, 1),
                    ('savings', 'Savings', 0, 0, 0, 2);
                INSERT INTO category_groups VALUES ('everyday', 'Everyday', 0, 0, 0, 1);
                INSERT INTO categories VALUES
                    ('groceries', 'Groceries', 'everyday', 0, 0, 0, 1),
                    ('utilities', 'Utilities', 'everyday', 0, 0, 0, 2);
                INSERT INTO category_mapping VALUES
                    ('raw-groceries', 'groceries'),
                    ('raw-utilities', 'utilities');
                INSERT INTO payees VALUES
                    ('coffee', 'Coffee', NULL, 0),
                    ('market', 'Market', NULL, 0);
                INSERT INTO payee_mapping VALUES
                    ('raw-coffee', 'coffee'),
                    ('raw-market', 'market');
                INSERT INTO transactions (
                    id, isParent, isChild, acct, category, amount, description, notes,
                    date, sort_order, tombstone, parent_id
                ) VALUES
                    ('checking-new', 0, 0, 'checking', 'raw-groceries', -100, 'raw-coffee',
                     'ordinary', 20260910, 50, 0, NULL),
                    ('split-parent', 1, 0, 'checking', NULL, -500, NULL,
                     'parent needle', 20260909, 40, 0, NULL),
                    ('split-match', 0, 1, 'checking', 'raw-groceries', -200, 'raw-market',
                     'child needle', 20260909, 30, 0, 'split-parent'),
                    ('split-context', 0, 1, 'checking', 'raw-utilities', -300, 'raw-coffee',
                     'sibling', 20260909, 20, 0, 'split-parent'),
                    ('savings-row', 0, 0, 'savings', 'raw-groceries', -400, 'raw-coffee',
                     'older', 20260901, 10, 0, NULL);
                """)
        }
        return try BudgetDatabase(databaseURL: url)
    }
}
