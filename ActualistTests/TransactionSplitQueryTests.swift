import Foundation
import GRDB
import Testing
@testable import Actualist

struct TransactionSplitQueryTests {
    @Test func groupedQueryFixturePinsOracleIdentityAndCaseIds() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "ActualistTests/Fixtures/ActualCore26_8_1/Splits/grouped-query-cases.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let oracle = object?["oracle"] as? [String: Any]
        let cases = object?["cases"] as? [[String: Any]] ?? []
        #expect(oracle?["tag"] as? String == "v26.8.1")
        #expect(oracle?["commit"] as? String == "063df03763ca772b51f6264752b88ddec22cfb8a")
        #expect(Set(cases.compactMap { $0["id"] as? String }) == [
            "split-modes-two-child-family",
            "child-note-search",
            "dead-parent-excludes-orphan",
            "flag-disagreement-parent-id-without-is-child",
            "default-order",
        ])
    }

    @Test func splitModesReturnActualFamilyShapes() async throws {
        let database = try exactSchemaDatabase(extraSQL: """
            INSERT INTO transactions (
                id, isParent, isChild, acct, category, amount, description, notes, date,
                sort_order, tombstone, parent_id, starting_balance_flag
            ) VALUES
            ('simple', 0, 0, 'checking', 'groceries', -1000, 'coffee', NULL, 20260820, 3, 0, NULL, 0),
            ('parent', 1, 0, 'checking', 'groceries', -5000, NULL, 'S01 parent', 20260815, 2, 0, NULL, 0),
            ('child-a', 0, 1, 'checking', 'groceries', -2000, 'coffee', 'child a', 20260815, 1, 0, 'parent', 0),
            ('child-b', 0, 1, 'checking', 'utilities', -3000, NULL, 'Q01-CHILD-NOTE', 20260815, 0, 0, 'parent', 0);
            """)

        let all = try await database.fetchTransactionPage(accountID: "checking", splits: .all)
        let inline = try await database.fetchTransactionPage(accountID: "checking", splits: .inline)
        let none = try await database.fetchTransactionPage(accountID: "checking", splits: TransactionSplitQueryMode.none)
        let grouped = try await database.fetchTransactionPage(accountID: "checking", splits: .grouped)

        #expect(all.transactions.map(\.id) == ["simple", "parent", "child-a", "child-b"])
        #expect(inline.transactions.map(\.id) == ["simple", "child-a", "child-b"])
        #expect(none.transactions.map(\.id) == ["simple", "parent"])
        #expect(grouped.transactions.map(\.id) == ["simple", "parent"])
        let family = try #require(grouped.transactions.first { $0.id == "parent" })
        #expect(family.isParent)
        #expect(family.category == nil)
        #expect(family.subtransactions.map(\.id) == ["child-a", "child-b"])
        #expect(family.subtransactions.map(\.isChild) == [true, true])
        #expect(family.subtransactions.map(\.notes) == ["child a", "Q01-CHILD-NOTE"])
    }

    @Test func searchAllReturnsMatchingChildAndGroupedReturnsFamily() async throws {
        let database = try exactSchemaDatabase(extraSQL: """
            INSERT INTO transactions (
                id, isParent, isChild, acct, category, amount, description, notes, date,
                sort_order, tombstone, parent_id
            ) VALUES
            ('parent', 1, 0, 'checking', NULL, -5000, NULL, 'S03 parent', 20260815, 2, 0, NULL),
            ('child-a', 0, 1, 'checking', 'groceries', -2000, 'child-a-payee', 'child a', 20260815, 1, 0, 'parent'),
            ('child-b', 0, 1, 'checking', NULL, -3000, NULL, 'Q01-CHILD-NOTE', 20260815, 0, 0, 'parent');
            INSERT INTO payees VALUES ('child-a-payee', 'SPLIT · Child A', NULL, 0);
            INSERT INTO payee_mapping VALUES ('child-a-payee', 'child-a-payee');
            """)

        let all = try await database.fetchTransactionPage(matching: "Q01-CHILD-NOTE", splits: .all)
        let grouped = try await database.fetchTransactionPage(matching: "Q01-CHILD-NOTE", splits: .grouped)
        let payee = try await database.fetchTransactionPage(matching: "SPLIT · Child A", splits: .all)
        let category = try await database.fetchTransactionPage(matching: "Groceries", splits: .all)

        #expect(all.transactions.map(\.id) == ["child-b"])
        #expect(all.transactions.first?.isChild == true)
        #expect(all.transactions.first?.notes == "Q01-CHILD-NOTE")
        #expect(grouped.transactions.map(\.id) == ["parent"])
        #expect(grouped.transactions.first?.subtransactions.map(\.id) == ["child-a", "child-b"])
        #expect(payee.transactions.map(\.id) == ["child-a"])
        #expect(category.transactions.map(\.id) == ["child-a"])
    }

    @Test func defaultAccountFeedHidesChildrenUntilSearch() async throws {
        let database = try exactSchemaDatabase(extraSQL: """
            INSERT INTO transactions (
                id, isParent, isChild, acct, category, amount, description, notes, date,
                sort_order, tombstone, parent_id
            ) VALUES
            ('parent', 1, 0, 'checking', NULL, -5000, NULL, 'S03 parent', 20260815, 2, 0, NULL),
            ('child-b', 0, 1, 'checking', NULL, -3000, NULL, 'Q01-CHILD-NOTE', 20260815, 0, 0, 'parent');
            """)

        let feed = try await database.fetchTransactions(accountID: "checking")
        let search = try await database.fetchTransactions(accountID: "checking", matching: "Q01-CHILD-NOTE")
        #expect(feed.map(\.id) == ["parent"])
        #expect(feed.first?.subtransactions.map(\.id) == ["child-b"])
        #expect(search.map(\.id) == ["child-b"])
    }

    @Test func deadParentExcludesOrphanFromLiveReadsAndBalances() async throws {
        let database = try exactSchemaDatabase(extraSQL: """
            INSERT INTO transactions (
                id, isParent, isChild, acct, category, amount, description, notes, date,
                sort_order, tombstone, parent_id
            ) VALUES
            ('simple', 0, 0, 'checking', 'groceries', -1000, 'coffee', NULL, 20260820, 3, 0, NULL),
            ('dead-parent', 1, 0, 'checking', NULL, -5000, NULL, 'dead', 20260815, 2, 1, NULL),
            ('orphan', 0, 1, 'checking', 'groceries', -2000, 'coffee', 'orphan', 20260815, 1, 0, 'dead-parent'),
            ('missing-parent-child', 0, 1, 'checking', 'groceries', -900, 'coffee', 'missing', 20260814, 0, 0, 'no-such-parent');
            """)

        let all = try await database.fetchTransactionPage(accountID: "checking", splits: .all)
        let inline = try await database.fetchTransactionPage(accountID: "checking", splits: .inline)
        let balances = try await database.accountBalances()
        #expect(all.transactions.map(\.id) == ["simple"])
        #expect(inline.transactions.map(\.id) == ["simple"])
        #expect(balances["checking"] == -1_000)
    }

    @Test func parentIdWithoutIsChildIsNotAnEffectiveChild() async throws {
        let database = try exactSchemaDatabase(extraSQL: """
            INSERT INTO transactions (
                id, isParent, isChild, acct, category, amount, description, notes, date,
                sort_order, tombstone, parent_id
            ) VALUES
            ('flagged', 0, 0, 'checking', 'groceries', -1000, 'coffee', NULL, 20260815, 1, 0, 'someone');
            """)

        let all = try await database.fetchTransactionPage(accountID: "checking", splits: .all)
        let grouped = try await database.fetchTransactionPage(accountID: "checking", splits: .grouped)
        #expect(all.transactions.map(\.id) == ["flagged"])
        #expect(all.transactions.first?.isChild == false)
        #expect(all.transactions.first?.parentID == nil)
        #expect(grouped.transactions.map(\.id) == ["flagged"])
        #expect(grouped.transactions.first?.subtransactions.isEmpty == true)
    }

    @Test func childFlagWithoutParentIdIsExcludedFromInternalView() async throws {
        let database = try exactSchemaDatabase(extraSQL: """
            INSERT INTO transactions (
                id, isParent, isChild, acct, category, amount, description, notes, date,
                sort_order, tombstone, parent_id
            ) VALUES
            ('broken', 0, 1, 'checking', 'groceries', -1000, 'coffee', NULL, 20260815, 1, 0, NULL);
            """)

        let all = try await database.fetchTransactionPage(accountID: "checking", splits: .all)
        #expect(all.transactions.isEmpty)
    }

    @Test func defaultOrderIsDateStartingBalanceSortThenId() async throws {
        let database = try exactSchemaDatabase(extraSQL: """
            INSERT INTO transactions (
                id, isParent, isChild, acct, category, amount, description, notes, date,
                sort_order, tombstone, parent_id, starting_balance_flag
            ) VALUES
            ('older', 0, 0, 'checking', 'groceries', -1000, 'coffee', NULL, 20260810, 9, 0, NULL, 0),
            ('starting', 0, 0, 'checking', 'groceries', 5000, 'coffee', NULL, 20260815, 8, 0, NULL, 1),
            ('regular', 0, 0, 'checking', 'groceries', -2000, 'coffee', NULL, 20260815, 7, 0, NULL, 0),
            ('newer', 0, 0, 'checking', 'groceries', -3000, 'coffee', NULL, 20260820, 1, 0, NULL, 0);
            """)

        let all = try await database.fetchTransactionPage(accountID: "checking", splits: .all)
        #expect(all.transactions.map(\.id) == ["newer", "regular", "starting", "older"])
    }

    @Test func balancesAndReportsCountLiveChildrenOnce() async throws {
        let database = try exactSchemaDatabase(extraSQL: """
            INSERT INTO transactions (
                id, isParent, isChild, acct, category, amount, description, notes, date,
                sort_order, tombstone, parent_id
            ) VALUES
            ('parent', 1, 0, 'checking', NULL, -5000, NULL, NULL, 20260815, 2, 0, NULL),
            ('child-a', 0, 1, 'checking', 'groceries', -2000, 'coffee', NULL, 20260815, 1, 0, 'parent'),
            ('child-b', 0, 1, 'checking', 'utilities', -3000, 'coffee', NULL, 20260815, 0, 0, 'parent'),
            ('mismatch-parent', 1, 0, 'checking', NULL, -10000, NULL, NULL, 20260816, 5, 0, NULL),
            ('mismatch-child', 0, 1, 'checking', 'groceries', -4000, 'coffee', NULL, 20260816, 4, 0, 'mismatch-parent');
            """)

        let balances = try await database.accountBalances()
        #expect(balances["checking"] == -9_000)

        let snapshot = try await database.fetchReportsDashboard(
            range: ReportDateRange(anchorMonth: "2026-08", startDay: "2026-08-01", endDay: "2026-08-31")
        )
        #expect(snapshot.netWorth.balance == -9_000)
    }

    @Test func mismatchErrorDecodesOnParentAndChildrenStayPresent() async throws {
        let errorJSON = "{\"type\":\"SplitTransactionError\",\"version\":1,\"difference\":-1000}"
        let database = try exactSchemaDatabase(extraSQL: """
            INSERT INTO transactions (
                id, isParent, isChild, acct, category, amount, description, notes, date,
                sort_order, tombstone, parent_id, error
            ) VALUES
            ('parent', 1, 0, 'checking', NULL, -10000, NULL, 'S07', 20260815, 2, 0, NULL, '\(errorJSON)'),
            ('child-a', 0, 1, 'checking', 'groceries', -4000, 'coffee', 'a', 20260815, 1, 0, 'parent', NULL),
            ('child-b', 0, 1, 'checking', 'utilities', -5000, 'coffee', 'b', 20260815, 0, 0, 'parent', NULL);
            """)

        let grouped = try await database.fetchTransactions(accountID: "checking")
        let parent = try #require(grouped.first { $0.id == "parent" })
        #expect(parent.error?.type == "SplitTransactionError")
        #expect(parent.error?.version == 1)
        #expect(parent.error?.difference == -1_000)
        #expect(parent.subtransactions.map(\.id) == ["child-a", "child-b"])
        #expect(parent.subtransactions.map(\.error) == [nil, nil])
    }

    @Test func tombstonedChildIsOmittedAndParentRemains() async throws {
        let database = try exactSchemaDatabase(extraSQL: """
            INSERT INTO transactions (
                id, isParent, isChild, acct, category, amount, description, notes, date,
                sort_order, tombstone, parent_id
            ) VALUES
            ('parent', 1, 0, 'checking', NULL, -5000, NULL, NULL, 20260815, 2, 0, NULL),
            ('alive', 0, 1, 'checking', 'groceries', -2000, 'coffee', NULL, 20260815, 1, 0, 'parent'),
            ('dead-child', 0, 1, 'checking', 'utilities', -3000, 'coffee', NULL, 20260815, 0, 1, 'parent');
            """)

        let grouped = try await database.fetchTransactions(accountID: "checking")
        #expect(grouped.first?.subtransactions.map(\.id) == ["alive"])
        let balances = try await database.accountBalances()
        #expect(balances["checking"] == -2_000)
    }

    @Test func groupedOrderingIndexesByTransactionID() {
        let childA = queryTransaction(id: "a-1", isChild: true, parentID: "a")
        let childB = queryTransaction(id: "a-2", isChild: true, parentID: "a")
        let parent = queryTransaction(id: "a", isParent: true, children: [childA, childB])
        let assembled = [
            queryTransaction(id: "c"),
            queryTransaction(id: nil),
            parent,
            queryTransaction(id: "b"),
        ]

        let ordered = TransactionGroupedOrdering.transactions(
            assembled,
            orderedByGroupIDs: ["a", "missing", "b", "c"]
        )

        #expect(ordered.map(\.id) == ["a", "b", "c"])
        #expect(ordered[0].subtransactions.map(\.id) == ["a-1", "a-2"])
    }

    @Test func unlimitedGroupedReadsUseAssembledLiveRowsPlan() {
        #expect(GroupedTransactionPagePlan.make(limit: nil, hasQueryFilter: false) == .assembledLiveRows)
        #expect(GroupedTransactionPagePlan.make(limit: 1, hasQueryFilter: false) == .familyLookup)
        #expect(GroupedTransactionPagePlan.make(limit: nil, hasQueryFilter: true) == .familyLookup)
        #expect(GroupedTransactionPagePlan.make(limit: 50, hasQueryFilter: true) == .familyLookup)
    }

    @Test func unlimitedGroupedReadReturnsCompleteFamiliesWithoutLeakingChildren() async throws {
        let database = try exactSchemaDatabase(extraSQL: """
            INSERT INTO transactions (
                id, isParent, isChild, acct, category, amount, description, notes, date,
                sort_order, tombstone, parent_id, starting_balance_flag
            ) VALUES
            ('simple-new', 0, 0, 'checking', 'groceries', -100, 'coffee', NULL, 20260830, 40, 0, NULL, 0),
            ('parent-new', 1, 0, 'checking', NULL, -5000, NULL, 'parent new', 20260820, 30, 0, NULL, 0),
            ('parent-new-b', 0, 1, 'checking', 'utilities', -3000, 'coffee', 'newer-b', 20260820, 20, 0, 'parent-new', 0),
            ('parent-new-a', 0, 1, 'checking', 'groceries', -2000, 'coffee', 'newer-a', 20260820, 10, 0, 'parent-new', 0),
            ('simple-old', 0, 0, 'checking', 'groceries', -200, 'coffee', NULL, 20260810, 9, 0, NULL, 0),
            ('parent-old', 1, 0, 'checking', NULL, -4000, NULL, 'parent old', 20260801, 8, 0, NULL, 0),
            ('parent-old-a', 0, 1, 'checking', 'groceries', -1500, 'coffee', 'older-a', 20260801, 7, 0, 'parent-old', 0),
            ('parent-old-b', 0, 1, 'checking', 'utilities', -2500, 'coffee', 'older-b', 20260801, 6, 0, 'parent-old', 0);
            """)

        let grouped = try await database.fetchTransactions(accountID: "checking")
        let none = try await database.fetchTransactionPage(accountID: "checking", splits: TransactionSplitQueryMode.none)

        #expect(grouped.map(\.id) == ["simple-new", "parent-new", "simple-old", "parent-old"])
        #expect(grouped.map(\.id) == none.transactions.map(\.id))
        #expect(grouped.flatMap(\.subtransactions).map(\.id) == [
            "parent-new-b", "parent-new-a", "parent-old-a", "parent-old-b",
        ])
        let parentNew = try #require(grouped.first { $0.id == "parent-new" })
        #expect(parentNew.subtransactions.map(\.id) == ["parent-new-b", "parent-new-a"])
        #expect(Set(parentNew.subtransactions.map(\.id)).count == parentNew.subtransactions.count)
        let parentOld = try #require(grouped.first { $0.id == "parent-old" })
        #expect(parentOld.subtransactions.map(\.id) == ["parent-old-a", "parent-old-b"])
        #expect(grouped.allSatisfy { $0.isChild == false })
        #expect(!grouped.contains { $0.id == "parent-new-a" || $0.id == "parent-old-b" })
    }

    @Test func paginatedGroupedReadKeepsWholeFamiliesAndStableOrder() async throws {
        let database = try exactSchemaDatabase(extraSQL: """
            INSERT INTO transactions (
                id, isParent, isChild, acct, category, amount, description, notes, date,
                sort_order, tombstone, parent_id, starting_balance_flag
            ) VALUES
            ('simple-new', 0, 0, 'checking', 'groceries', -100, 'coffee', NULL, 20260830, 40, 0, NULL, 0),
            ('parent-new', 1, 0, 'checking', NULL, -5000, NULL, 'parent new', 20260820, 30, 0, NULL, 0),
            ('parent-new-b', 0, 1, 'checking', 'utilities', -3000, 'coffee', 'newer-b', 20260820, 20, 0, 'parent-new', 0),
            ('parent-new-a', 0, 1, 'checking', 'groceries', -2000, 'coffee', 'newer-a', 20260820, 10, 0, 'parent-new', 0),
            ('simple-old', 0, 0, 'checking', 'groceries', -200, 'coffee', NULL, 20260810, 9, 0, NULL, 0),
            ('parent-old', 1, 0, 'checking', NULL, -4000, NULL, 'parent old', 20260801, 8, 0, NULL, 0),
            ('parent-old-a', 0, 1, 'checking', 'groceries', -1500, 'coffee', 'older-a', 20260801, 7, 0, 'parent-old', 0),
            ('parent-old-b', 0, 1, 'checking', 'utilities', -2500, 'coffee', 'older-b', 20260801, 6, 0, 'parent-old', 0);
            """)

        let first = try await database.fetchTransactionPage(accountID: "checking", limit: 2, splits: .grouped)
        let second = try await database.fetchTransactionPage(
            accountID: "checking",
            limit: 2,
            offset: 2,
            splits: .grouped
        )
        let unlimited = try await database.fetchTransactions(accountID: "checking")

        #expect(first.transactions.map(\.id) == ["simple-new", "parent-new"])
        #expect(first.transactions.count == 2)
        #expect(!first.reachedEnd)
        let pagedFamily = try #require(first.transactions.first { $0.id == "parent-new" })
        #expect(pagedFamily.subtransactions.map(\.id) == ["parent-new-b", "parent-new-a"])
        #expect(!first.transactions.contains { $0.id?.hasPrefix("parent-new-") == true })
        #expect(second.transactions.map(\.id) == ["simple-old", "parent-old"])
        #expect(second.reachedEnd)
        #expect(second.transactions.first { $0.id == "parent-old" }?.subtransactions.map(\.id) == [
            "parent-old-a", "parent-old-b",
        ])
        #expect((first.transactions + second.transactions).map(\.id) == unlimited.map(\.id))
    }

    @Test func groupedChildPayeeAndCategorySearchReturnsTheFamily() async throws {
        let database = try exactSchemaDatabase(extraSQL: """
            INSERT INTO transactions (
                id, isParent, isChild, acct, category, amount, description, notes, date,
                sort_order, tombstone, parent_id
            ) VALUES
            ('parent', 1, 0, 'checking', NULL, -5000, NULL, 'S03 parent', 20260815, 2, 0, NULL),
            ('child-a', 0, 1, 'checking', 'groceries', -2000, 'child-a-payee', 'child a', 20260815, 1, 0, 'parent'),
            ('child-b', 0, 1, 'checking', NULL, -3000, NULL, 'Q01-CHILD-NOTE', 20260815, 0, 0, 'parent');
            INSERT INTO payees VALUES ('child-a-payee', 'SPLIT · Child A', NULL, 0);
            INSERT INTO payee_mapping VALUES ('child-a-payee', 'child-a-payee');
            """)

        let note = try await database.fetchTransactionPage(matching: "Q01-CHILD-NOTE", splits: .grouped)
        let payee = try await database.fetchTransactionPage(matching: "SPLIT · Child A", splits: .grouped)
        let category = try await database.fetchTransactionPage(matching: "Groceries", splits: .grouped)

        #expect(note.transactions.map(\.id) == ["parent"])
        #expect(payee.transactions.map(\.id) == ["parent"])
        #expect(category.transactions.map(\.id) == ["parent"])
        #expect(note.transactions.first?.subtransactions.map(\.id) == ["child-a", "child-b"])
        #expect(payee.transactions.first?.subtransactions.map(\.id) == ["child-a", "child-b"])
        #expect(category.transactions.first?.subtransactions.map(\.id) == ["child-a", "child-b"])
    }

    @Test func monthBoundedInlineReadDoesNotMaterializeOtherMonths() async throws {
        let database = try exactSchemaDatabase(extraSQL: """
            INSERT INTO transactions (
                id, isParent, isChild, acct, category, amount, description, notes, date,
                sort_order, tombstone, parent_id
            ) VALUES
            ('july-simple', 0, 0, 'checking', NULL, -1000, 'coffee', NULL, 20260720, 5, 0, NULL),
            ('july-parent', 1, 0, 'checking', NULL, -5000, NULL, NULL, 20260715, 4, 0, NULL),
            ('july-child', 0, 1, 'checking', NULL, -2000, 'coffee', NULL, 20260715, 3, 0, 'july-parent'),
            ('june-simple', 0, 0, 'checking', NULL, -900, 'coffee', NULL, 20260610, 2, 0, NULL),
            ('june-child', 0, 1, 'checking', NULL, -800, 'coffee', NULL, 20260601, 1, 0, 'missing-parent');
            """)

        let july = try await database.fetchTransactionPage(splits: .inline, month: "2026-07")
        let june = try await database.fetchTransactionPage(splits: .inline, month: "2026-06")
        let invalid = try await database.fetchTransactionPage(splits: .inline, month: "not-a-month")

        #expect(july.transactions.map(\.id) == ["july-simple", "july-child"])
        #expect(!july.transactions.contains { $0.id == "june-simple" || $0.id == "july-parent" })
        #expect(june.transactions.map(\.id) == ["june-simple"])
        #expect(invalid.transactions.isEmpty)
    }

    @Test func twoChildFamilyIsIdentifiedAsParentOnPermissiveFixture() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ActualistSplitQueryPermissive-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtureURL = directory.appending(path: "db.sqlite")
        let queue = try DatabaseQueue(path: fixtureURL.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, offbudget INTEGER, closed INTEGER, tombstone INTEGER, sort_order INTEGER
                );
                CREATE TABLE category_groups (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, is_income INTEGER, hidden INTEGER, tombstone INTEGER, sort_order INTEGER
                );
                CREATE TABLE categories (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, cat_group TEXT, is_income INTEGER, hidden INTEGER, tombstone INTEGER, sort_order INTEGER
                );
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY, acct TEXT, date INTEGER, amount INTEGER, category TEXT, tombstone INTEGER, parent_id TEXT, is_parent INTEGER
                );
                INSERT INTO accounts VALUES ('checking', 'Checking', 0, 0, 0, 1);
                INSERT INTO category_groups VALUES ('group', 'Everyday', 0, 0, 0, 1);
                INSERT INTO categories VALUES ('groceries', 'Groceries', 'group', 0, 0, 0, 1);
                INSERT INTO transactions VALUES ('txn', 'checking', 20260703, -12345, 'groceries', 0, NULL, 0);
                INSERT INTO transactions VALUES ('split', 'checking', 20260801, -5000, NULL, 0, NULL, 1);
                INSERT INTO transactions VALUES ('split-a', 'checking', 20260801, -2000, 'groceries', 0, 'split', 0);
                INSERT INTO transactions VALUES ('split-b', 'checking', 20260801, -3000, 'groceries', 0, 'split', 0);
                """)
        }
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let transactions = try await database.fetchTransactions(accountID: "checking")
        let split = try #require(transactions.first { $0.id == "split" })
        #expect(split.isParent)
        #expect(split.subtransactions.count == 2)
        #expect(Set(split.subtransactions.compactMap(\.id)) == ["split-a", "split-b"])
        #expect(split.subtransactions.allSatisfy { $0.isChild })
    }

    private func queryTransaction(
        id: String?,
        isParent: Bool = false,
        isChild: Bool = false,
        parentID: String? = nil,
        children: [ActualTransaction] = []
    ) -> ActualTransaction {
        ActualTransaction(
            id: id,
            account: "checking",
            date: "2026-08-15",
            amount: -1000,
            payee: nil,
            payeeName: nil,
            importedPayee: nil,
            category: isParent ? nil : "groceries",
            notes: nil,
            cleared: nil,
            subtransactions: children,
            isParent: isParent,
            isChild: isChild,
            parentID: parentID
        )
    }

    private func exactSchemaDatabase(extraSQL: String) throws -> BudgetDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ActualistSplitQuery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "db.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    offbudget INTEGER DEFAULT 0,
                    closed INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0,
                    sort_order INTEGER
                );
                CREATE TABLE category_groups (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    is_income INTEGER DEFAULT 0,
                    hidden INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0,
                    sort_order INTEGER
                );
                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    cat_group TEXT,
                    is_income INTEGER DEFAULT 0,
                    hidden INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0,
                    sort_order INTEGER
                );
                CREATE TABLE category_mapping (
                    id TEXT PRIMARY KEY,
                    transferId TEXT
                );
                CREATE TABLE payees (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    transfer_acct TEXT,
                    tombstone INTEGER DEFAULT 0
                );
                CREATE TABLE payee_mapping (
                    id TEXT PRIMARY KEY,
                    targetId TEXT
                );
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0,
                    acct TEXT,
                    category TEXT,
                    amount INTEGER,
                    description TEXT,
                    notes TEXT,
                    date INTEGER,
                    financial_id TEXT,
                    error TEXT,
                    imported_description TEXT,
                    starting_balance_flag INTEGER DEFAULT 0,
                    transferred_id TEXT,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0,
                    parent_id TEXT,
                    cleared INTEGER DEFAULT 1,
                    reconciled INTEGER DEFAULT 0
                );
                INSERT INTO accounts VALUES ('checking', 'Checking', 0, 0, 0, 1);
                INSERT INTO category_groups VALUES ('group', 'Everyday', 0, 0, 0, 1);
                INSERT INTO categories VALUES ('groceries', 'Groceries', 'group', 0, 0, 0, 1);
                INSERT INTO categories VALUES ('utilities', 'Utilities', 'group', 0, 0, 0, 2);
                INSERT INTO category_mapping VALUES ('groceries', 'groceries');
                INSERT INTO category_mapping VALUES ('utilities', 'utilities');
                INSERT INTO payees VALUES ('coffee', 'Coffee Shop', NULL, 0);
                INSERT INTO payee_mapping VALUES ('coffee', 'coffee');
                \(extraSQL)
                """)
        }
        return try BudgetDatabase(databaseURL: url)
    }
}
