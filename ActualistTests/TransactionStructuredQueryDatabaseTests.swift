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
        #expect(page.transactions.first?.category == nil)
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

    @Test func flatParentAndChildMatchesContributeEachPhysicalIDOnlyOnce() async throws {
        let database = try database()
        let query = TransactionFeedQuery(text: "common needle")

        let page = try await database.fetchTransactionQueryPage(scope: .spending, query: query)
        let drilldown = try await database.fetchTransactionDrilldown(
            TransactionDrilldownRequest(scope: .spending, query: query)
        )

        #expect(page.transactions.map(\.id) == ["checking-new", "split-parent", "split-match"])
        #expect(page.totalMatchCount == 3)
        #expect(page.matchingTransactionIDs == ["checking-new", "split-parent", "split-match"])
        #expect(page.contributingTransactionIDs == ["checking-new", "split-match"])
        #expect(page.attachedContextTransactionIDs == ["split-context"])
        #expect(drilldown.contributingTransactions.map(\.id) == ["checking-new", "split-match"])
    }

    @Test func nullBlankNegativeAndSetIDOperationsRemainDistinct() async throws {
        let database = try database()
        let explicitNull = TransactionFeedQuery(conditions: [.payee(.equals(nil))])
        let blankScalar = TransactionFeedQuery(conditions: [.payee(.equals("  "))])
        let blankNegativeScalar = TransactionFeedQuery(conditions: [.payee(.doesNotEqual("\n"))])
        let oneOf = TransactionFeedQuery(conditions: [.payee(.oneOf([nil, "market", " "]))])
        let emptyOneOf = TransactionFeedQuery(conditions: [.payee(.oneOf([" "]))])
        let notMarket = TransactionFeedQuery(conditions: [.payee(.doesNotEqual("market"))])
        let notOneOfMarket = TransactionFeedQuery(conditions: [.payee(.notOneOf(["market"]))])
        let emptyNotOneOf = TransactionFeedQuery(conditions: [.payee(.notOneOf([" "]))])

        let nullPage = try await database.fetchTransactionQueryPage(scope: .spending, query: explicitNull)
        let blankPage = try await database.fetchTransactionQueryPage(scope: .spending, query: blankScalar)
        let blankNegativePage = try await database.fetchTransactionQueryPage(
            scope: .spending,
            query: blankNegativeScalar
        )
        let oneOfPage = try await database.fetchTransactionQueryPage(scope: .spending, query: oneOf)
        let emptyOneOfPage = try await database.fetchTransactionQueryPage(scope: .spending, query: emptyOneOf)
        let notMarketPage = try await database.fetchTransactionQueryPage(scope: .spending, query: notMarket)
        let notOneOfPage = try await database.fetchTransactionQueryPage(scope: .spending, query: notOneOfMarket)
        let emptyNotOneOfPage = try await database.fetchTransactionQueryPage(
            scope: .spending,
            query: emptyNotOneOf
        )

        #expect(nullPage.transactions.map(\.id) == ["split-parent"])
        #expect(nullPage.matchingTransactionIDs == ["split-parent"])
        #expect(blankPage.totalMatchCount == 0)
        #expect(blankNegativePage.totalMatchCount == 0)
        #expect(oneOfPage.transactions.map(\.id) == ["split-parent"])
        #expect(oneOfPage.matchingTransactionIDs == ["split-parent", "split-match"])
        #expect(emptyOneOfPage.totalMatchCount == 0)
        #expect(notMarketPage.matchingTransactionIDs == [
            "checking-new", "split-parent", "split-context", "savings-row",
        ])
        #expect(notOneOfPage.matchingTransactionIDs == notMarketPage.matchingTransactionIDs)
        #expect(emptyNotOneOfPage.totalMatchCount == 0)
    }

    @Test func scalarNullCategoryExcludesTransfersAndSplitParentsAcrossTransferStorageShapes() async throws {
        let mappedTransferDatabase = try categoryNullDatabase(transferColumn: .actualMapped)
        let directTransferDatabase = try categoryNullDatabase(transferColumn: .directCompatibility)
        let scalarNull = TransactionFeedQuery(conditions: [.category(.equals(nil))])

        let mappedPage = try await mappedTransferDatabase.fetchTransactionQueryPage(
            scope: .spending,
            query: scalarNull
        )
        let directPage = try await directTransferDatabase.fetchTransactionQueryPage(
            scope: .spending,
            query: scalarNull
        )

        #expect(mappedPage.transactions.map(\.id) == ["null-normal"])
        #expect(mappedPage.matchingTransactionIDs == ["null-normal"])
        #expect(mappedPage.totalMatchCount == 1)
        #expect(directPage.transactions.map(\.id) == ["null-normal"])
        #expect(directPage.matchingTransactionIDs == ["null-normal"])
        #expect(directPage.totalMatchCount == 1)

        let mixedNullSet = TransactionFeedQuery(
            conditions: [.category(.oneOf([nil, "groceries"]))]
        )
        let mixedPage = try await mappedTransferDatabase.fetchTransactionQueryPage(
            scope: .spending,
            query: mixedNullSet
        )

        #expect(mixedPage.transactions.map(\.id) == [
            "null-normal", "null-transfer", "split-parent", "categorized-normal",
        ])
        #expect(mixedPage.matchingTransactionIDs == [
            "null-normal", "null-transfer", "split-parent", "split-child", "categorized-normal",
        ])
        #expect(
            mixedPage.transactions.first(where: { $0.id == "split-parent" })?.subtransactions.map(\.id)
                == ["split-child"]
        )
    }

    @Test func everyDateOperationUsesCanonicalInclusiveBoundaries() async throws {
        let database = try database()
        let septemberNinth = try #require(TransactionQueryDay(rawValue: "2026-09-09"))

        func query(_ operation: TransactionQueryDateOperation) -> TransactionFeedQuery {
            TransactionFeedQuery(conditions: [
                .date(TransactionQueryDateCondition(operation: operation, day: septemberNinth)),
            ])
        }

        let exact = try await database.fetchTransactionQueryPage(scope: .spending, query: query(.isOn))
        let approximate = try await database.fetchTransactionQueryPage(
            scope: .spending,
            query: query(.isApproximately)
        )
        let after = try await database.fetchTransactionQueryPage(scope: .spending, query: query(.isAfter))
        let onOrAfter = try await database.fetchTransactionQueryPage(
            scope: .spending,
            query: query(.isOnOrAfter)
        )
        let before = try await database.fetchTransactionQueryPage(scope: .spending, query: query(.isBefore))
        let onOrBefore = try await database.fetchTransactionQueryPage(
            scope: .spending,
            query: query(.isOnOrBefore)
        )

        #expect(exact.transactions.map(\.id) == ["split-parent"])
        #expect(approximate.transactions.map(\.id) == ["checking-new", "split-parent"])
        #expect(after.transactions.map(\.id) == ["checking-new"])
        #expect(onOrAfter.transactions.map(\.id) == ["checking-new", "split-parent"])
        #expect(before.transactions.map(\.id) == ["savings-row"])
        #expect(onOrBefore.transactions.map(\.id) == ["split-parent", "savings-row"])
    }

    @Test func statusWithDateAndAccountConditionsMatchesPhysicalChildren() async throws {
        let database = try database()
        let day = try #require(TransactionQueryDay(rawValue: "2026-09-09"))
        let query = TransactionFeedQuery(
            status: .uncleared,
            conditions: [
                .date(TransactionQueryDateCondition(operation: .isOn, day: day)),
                .account(.equals("checking")),
            ]
        )

        let page = try await database.fetchTransactionQueryPage(scope: .spending, query: query)

        #expect(page.transactions.map(\.id) == ["split-parent"])
        #expect(page.matchingTransactionIDs == ["split-match"])
        #expect(page.contributingTransactionIDs == ["split-match"])
        #expect(page.attachedContextTransactionIDs == ["split-parent", "split-context"])
    }

    @Test func accountScopeZeroResultAndMalformedFamiliesKeepExactOffsets() async throws {
        let database = try database()
        let missing = TransactionFeedQuery(conditions: [.category(.equals("utilities"))])
        let coffee = TransactionFeedQuery(conditions: [.payee(.equals("coffee"))])

        let empty = try await database.fetchTransactionQueryPage(
            scope: .account("savings"),
            query: missing,
            limit: 1,
            offset: 7
        )
        let live = try await database.fetchTransactionQueryPage(scope: .spending, query: coffee)

        #expect(empty.transactions.isEmpty)
        #expect(empty.totalMatchCount == 0)
        #expect(empty.nextOffset == 7)
        #expect(empty.reachedEnd)
        #expect(!live.matchingTransactionIDs.contains("dead-child"))
        #expect(!live.matchingTransactionIDs.contains("missing-parent-child"))
    }

    @Test func missingStatusColumnsUseTheKnownUnclearedCompatibilityProjection() async throws {
        let database = try TransactionStatusFilterTestSupport.legacyDatabaseWithoutStatusColumns()
        let query = TransactionFeedQuery(
            status: .uncleared,
            conditions: [.category(.equals(nil))]
        )

        let page = try await database.fetchTransactionQueryPage(
            scope: .account("checking"),
            query: query
        )

        #expect(page.transactions.map(\.id) == ["legacy-no-status"])
        #expect(page.matchingTransactionIDs == ["legacy-no-status"])
        #expect(page.totalMatchCount == 1)
    }

    @Test func drilldownReturnsUnpagedContributorsWithoutCountingContext() async throws {
        let database = try database()
        let query = TransactionFeedQuery(conditions: [.category(.equals("groceries"))])

        let result = try await database.fetchTransactionDrilldown(
            TransactionDrilldownRequest(scope: .spending, query: query)
        )

        #expect(result.displayTransactions.map(\.id) == ["checking-new", "split-parent", "savings-row"])
        #expect(result.totalMatchCount == 3)
        #expect(result.matchingTransactionIDs == ["checking-new", "split-match", "savings-row"])
        #expect(result.contributingTransactions.map(\.id) == ["checking-new", "split-match", "savings-row"])
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
                    date, sort_order, tombstone, parent_id, cleared, reconciled
                ) VALUES
                    ('checking-new', 0, 0, 'checking', 'raw-groceries', -100, 'raw-coffee',
                     'ordinary common needle', 20260910, 50, 0, NULL, 0, 0),
                    ('split-parent', 1, 0, 'checking', 'raw-groceries', -500, NULL,
                     'parent needle common needle', 20260909, 40, 0, NULL, 1, 0),
                    ('split-match', 0, 1, 'checking', 'raw-groceries', -200, 'raw-market',
                     'child needle common needle', 20260909, 30, 0, 'split-parent', 0, 0),
                    ('split-context', 0, 1, 'checking', 'raw-utilities', -300, 'raw-coffee',
                     'sibling', 20260909, 20, 0, 'split-parent', 1, 1),
                    ('savings-row', 0, 0, 'savings', 'raw-groceries', -400, 'raw-coffee',
                     'older', 20260901, 10, 0, NULL, 0, 0),
                    ('dead-parent', 1, 0, 'checking', NULL, -100, NULL,
                     'dead', 20260908, 8, 1, NULL, 0, 0),
                    ('dead-child', 0, 1, 'checking', 'raw-groceries', -100, 'raw-coffee',
                     'dead child', 20260908, 7, 0, 'dead-parent', 0, 0),
                    ('missing-parent-child', 0, 1, 'checking', 'raw-groceries', -100, 'raw-coffee',
                     'missing parent', 20260908, 6, 0, 'missing-parent', 0, 0);
                """)
        }
        return try BudgetDatabase(databaseURL: url)
    }

    private enum TransferStorageColumn: String {
        case actualMapped = "transferred_id"
        case directCompatibility = "transfer_id"
    }

    private func categoryNullDatabase(transferColumn: TransferStorageColumn) throws -> BudgetDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ActualistCategoryNull-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "db.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        let transferColumn = transferColumn.rawValue
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY, isParent INTEGER DEFAULT 0, isChild INTEGER DEFAULT 0,
                    acct TEXT, category TEXT, amount INTEGER, description TEXT, notes TEXT,
                    date INTEGER, sort_order REAL, tombstone INTEGER DEFAULT 0,
                    parent_id TEXT, \(transferColumn) TEXT
                );
                INSERT INTO transactions (
                    id, isParent, isChild, acct, category, amount, date, sort_order,
                    tombstone, parent_id, \(transferColumn)
                ) VALUES
                    ('null-normal', 0, 0, 'checking', NULL, -100, 20260910, 40, 0, NULL, NULL),
                    ('null-transfer', 0, 0, 'checking', NULL, -100, 20260909, 30, 0, NULL, 'pair'),
                    ('split-parent', 1, 0, 'checking', 'groceries', -100, 20260908, 20, 0, NULL, NULL),
                    ('split-child', 0, 1, 'checking', 'groceries', -100, 20260908, 15, 0, 'split-parent', NULL),
                    ('categorized-normal', 0, 0, 'checking', 'groceries', -100, 20260907, 10, 0, NULL, NULL);
                """)
        }
        return try BudgetDatabase(databaseURL: url)
    }
}
