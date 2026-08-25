import Foundation
import GRDB
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func oldBudgetOpenCreatesAccountGroupSchemaWithoutChangingAccounts() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let accounts = try await database.fetchAccounts()
        let groups = try await database.fetchAccountGroups()

        #expect(try sqliteTables(at: fixtureURL).contains("account_groups"))
        #expect(try sqliteColumns("accounts", at: fixtureURL).contains("account_group_id"))
        #expect(accounts.map(\.id) == ["checking"])
        #expect(accounts.first?.accountGroupId == nil)
        #expect(groups.isEmpty)
    }

    @Test func initBackfillsStoredAccountGroupCRDTWithoutASecondPull() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0, 2);
            INSERT INTO messages_crdt (timestamp, dataset, row, column, value) VALUES
                ('2026-07-01T12:00:00.000Z-0000-remote', 'account_groups', 'cash', 'name', 'S:Cash'),
                ('2026-07-01T12:00:00.001Z-0000-remote', 'account_groups', 'cash', 'sort_order', 'N:16384'),
                ('2026-07-01T12:00:00.002Z-0000-remote', 'account_groups', 'cash', 'tombstone', 'N:0'),
                ('2026-07-01T12:00:01.000Z-0000-remote', 'accounts', 'checking', 'account_group_id', 'S:cash');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let accounts = Dictionary(
            uniqueKeysWithValues: try await database.fetchAccounts().map { ($0.id, $0) }
        )
        let groups = try await database.fetchAccountGroups()

        #expect(try sqliteTables(at: fixtureURL).contains("account_groups"))
        #expect(groups.map(\.id) == ["cash"])
        #expect(groups.first?.name == "Cash")
        #expect(groups.first?.sortOrder == 16_384)
        #expect(accounts["checking"]?.accountGroupId == "cash")
        #expect(accounts["savings"]?.accountGroupId == nil)
    }

    @Test func initBackfillKeepsTheNewestAccountGroupMembership() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO messages_crdt (timestamp, dataset, row, column, value) VALUES
                ('2026-07-01T12:00:00.000Z-0000-remote', 'account_groups', 'cash', 'name', 'S:Cash'),
                ('2026-07-01T12:00:00.001Z-0000-remote', 'account_groups', 'credit', 'name', 'S:Credit'),
                ('2026-07-01T12:00:01.000Z-0000-remote', 'accounts', 'checking', 'account_group_id', 'S:cash'),
                ('2026-07-01T12:00:02.000Z-0000-remote', 'accounts', 'checking', 'account_group_id', 'S:credit');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let checking = try #require(
            try await database.fetchAccounts().first { $0.id == "checking" }
        )

        #expect(checking.accountGroupId == "credit")
    }

    @Test func migratedSchemaAppliesInboundGroupAndMembershipMessages() async throws {
        let fixtureURL = try makeMigratedAccountGroupFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let name = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-remote",
            dataset: "account_groups",
            row: "cash",
            column: "name",
            serializedValue: LocalFirstSyncValue.string("Cash").serialized
        )
        let sortOrder = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.790Z-0000-remote",
            dataset: "account_groups",
            row: "cash",
            column: "sort_order",
            serializedValue: LocalFirstSyncValue.double(24_576.5).serialized
        )
        let membership = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:57.789Z-0000-remote",
            dataset: "accounts",
            row: "checking",
            column: "account_group_id",
            serializedValue: LocalFirstSyncValue.string("cash").serialized
        )

        let appliedCount = try await database.applyRemoteSyncMessages([name, sortOrder, membership])
        let groups = try await database.fetchAccountGroups()
        let checking = try #require(
            try await database.fetchAccounts().first { $0.id == "checking" }
        )

        #expect(appliedCount == 3)
        #expect(try await database.latestSyncTimestamp() == membership.timestamp)
        #expect(groups.map(\.id) == ["cash"])
        #expect(groups.first?.sortOrder == 24_576.5)
        #expect(checking.accountGroupId == "cash")
    }

    @Test func tombstoneAndClearedMembershipHideTheGroupAndUngroupThatAccount() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0, 2);
            INSERT INTO messages_crdt (timestamp, dataset, row, column, value) VALUES
                ('2026-07-01T12:00:00.000Z-0000-remote', 'account_groups', 'cash', 'name', 'S:Cash'),
                ('2026-07-01T12:00:00.001Z-0000-remote', 'account_groups', 'cash', 'tombstone', 'N:0'),
                ('2026-07-01T12:00:01.000Z-0000-remote', 'accounts', 'checking', 'account_group_id', 'S:cash'),
                ('2026-07-01T12:00:01.001Z-0000-remote', 'accounts', 'savings', 'account_group_id', 'S:cash'),
                ('2026-07-01T12:00:02.000Z-0000-remote', 'accounts', 'checking', 'account_group_id', '0:'),
                ('2026-07-01T12:00:03.000Z-0000-remote', 'account_groups', 'cash', 'tombstone', 'N:1');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let accounts = Dictionary(
            uniqueKeysWithValues: try await database.fetchAccounts().map { ($0.id, $0) }
        )
        let groups = try await database.fetchAccountGroups()

        #expect(groups.isEmpty)
        #expect(accounts["checking"]?.accountGroupId == nil)
        #expect(accounts["savings"]?.accountGroupId == "cash")
    }

    @Test func membershipForAMissingAccountDoesNotInsertAGhostAccount() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO messages_crdt (timestamp, dataset, row, column, value) VALUES
                ('2026-07-01T12:00:01.000Z-0000-remote', 'accounts', 'missing', 'account_group_id', 'S:cash');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let accounts = try await database.fetchAccounts()

        #expect(accounts.map(\.id) == ["checking"])
        #expect(accounts.contains { $0.id == "missing" } == false)
    }

    @Test func storeOpenCachesLiveAccountGroupsFromABackfilledBudget() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(
            additionalFixtureSQL: """
                INSERT INTO messages_crdt (timestamp, dataset, row, column, value) VALUES
                    ('2026-07-01T12:00:00.000Z-0000-remote', 'account_groups', 'cash', 'name', 'S:Cash'),
                    ('2026-07-01T12:00:00.001Z-0000-remote', 'account_groups', 'cash', 'sort_order', 'N:16384'),
                    ('2026-07-01T12:00:00.002Z-0000-remote', 'account_groups', 'cash', 'tombstone', 'N:0'),
                    ('2026-07-01T12:00:01.000Z-0000-remote', 'accounts', 'checking', 'account_group_id', 'S:cash');
                """
        )
        let groups = bundle.store.accountGroups(budgetID: "group-1")
        let checking = try #require(
            bundle.store.accountDisplays(budgetID: "group-1").map(\.account).first { $0.id == "checking" }
        )

        #expect(groups.map(\.id) == ["cash"])
        #expect(groups.first?.name == "Cash")
        #expect(checking.accountGroupId == "cash")
    }

    @Test func storeReloadAfterRemoteGroupApplyRefreshesBothCaches() async throws {
        let store = try await makeOpenedWritableStore()
        let database = try #require(store.database)
        let messages = [
            ActualSyncDecodedMessage(
                timestamp: "2026-07-04T12:34:56.789Z-0000-remote",
                dataset: "account_groups",
                row: "cash",
                column: "name",
                serializedValue: LocalFirstSyncValue.string("Cash").serialized
            ),
            ActualSyncDecodedMessage(
                timestamp: "2026-07-04T12:34:56.790Z-0000-remote",
                dataset: "account_groups",
                row: "cash",
                column: "sort_order",
                serializedValue: LocalFirstSyncValue.int(16_384).serialized
            ),
            ActualSyncDecodedMessage(
                timestamp: "2026-07-04T12:34:57.789Z-0000-remote",
                dataset: "accounts",
                row: "checking",
                column: "account_group_id",
                serializedValue: LocalFirstSyncValue.string("cash").serialized
            )
        ]

        #expect(try await database.applyRemoteSyncMessages(messages) == 3)
        try await store.refreshAccountsWithBalances(budgetID: "group-1")

        #expect(store.accountGroups(budgetID: "group-1").map(\.id) == ["cash"])
        #expect(
            store.accountDisplays(budgetID: "group-1")
                .first { $0.account.id == "checking" }?
                .account.accountGroupId == "cash"
        )
    }

    private func makeMigratedAccountGroupFixture() throws -> URL {
        try makeSQLiteFixture(extraSQL: """
            CREATE TABLE account_groups (
                id TEXT PRIMARY KEY,
                name TEXT,
                sort_order REAL,
                tombstone INTEGER DEFAULT 0
            );
            ALTER TABLE accounts ADD COLUMN account_group_id TEXT DEFAULT NULL;
            """)
    }
}
