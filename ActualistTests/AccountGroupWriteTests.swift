import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func budgetWithoutGroupsMigrationRowCanStillCreateGroups() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()

        // The stored `__migrations__` table is the snapshot from the last
        // upload, so a budget downloaded before that snapshot gained the
        // account-groups migration lacks the row even when every peer
        // supports groups. Writes rely on the backfilled schema instead.
        #expect(try sqliteTables(at: fixtureURL).contains("account_groups"))
        let created = try await AccountGroupSQL.createAccountGroupMessages(
            groupID: "cash",
            name: "Cash",
            builder: &builder,
            in: database
        )
        #expect(try await database.commitLocalSyncMessagesAndEnqueue(created) == created.count)
        #expect(try await AccountGroupSQL.fetchAccountGroups(in: database).map(\.id) == ["cash"])
    }

    @Test func createAccountGroupAppendsSortOrderAndRejectsDuplicates() async throws {
        let database = try makeWritableAccountGroupDatabase()
        var builder = LocalFirstSyncMessageBuilder()

        let created = try await AccountGroupSQL.createAccountGroupMessages(
            groupID: "cash",
            name: "Cash",
            builder: &builder,
            in: database
        )
        #expect(try await database.commitLocalSyncMessagesAndEnqueue(created) == created.count)

        let groups = try await AccountGroupSQL.fetchAccountGroups(in: database)
        #expect(groups.map(\.id) == ["cash"])
        #expect(groups.first?.name == "Cash")
        #expect(groups.first?.sortOrder == 16_384)

        await #expect(
            throws: LocalFirstError.refusedChange("An account group named Cash already exists.")
        ) {
            _ = try await AccountGroupSQL.createAccountGroupMessages(
                groupID: "cash-2",
                name: "cash",
                builder: &builder,
                in: database
            )
        }
    }

    @Test func createAccountGroupReusesATombstonedNameWithANewID() async throws {
        let database = try makeWritableAccountGroupDatabase()
        var builder = LocalFirstSyncMessageBuilder()
        let created = try await AccountGroupSQL.createAccountGroupMessages(
            groupID: "cash",
            name: "Cash",
            builder: &builder,
            in: database
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(created)
        let deleted = try await AccountGroupSQL.deleteAccountGroupMessages(
            groupID: "cash",
            builder: &builder,
            in: database
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(deleted)

        let recreated = try await AccountGroupSQL.createAccountGroupMessages(
            groupID: "cash-new",
            name: "Cash",
            builder: &builder,
            in: database
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(recreated)
        let groups = try await AccountGroupSQL.fetchAccountGroups(in: database)
        #expect(groups.map(\.id) == ["cash-new"])
    }

    @Test func renameMoveUngroupAndDeleteAccountGroupsWritePerColumnMessages() async throws {
        let database = try makeWritableAccountGroupDatabase(
            extraSQL: "INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0, 2);"
        )
        var builder = LocalFirstSyncMessageBuilder()
        _ = try await database.commitLocalSyncMessagesAndEnqueue(
            try await AccountGroupSQL.createAccountGroupMessages(groupID: "cash", name: "Cash", builder: &builder, in: database)
            + (try await AccountGroupSQL.createAccountGroupMessages(groupID: "credit", name: "Credit", builder: &builder, in: database))
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(
            try await AccountGroupSQL.moveAccountToGroupMessages(
                accountID: "checking",
                groupID: "cash",
                builder: &builder,
                in: database
            )
            + (try await AccountGroupSQL.moveAccountToGroupMessages(
                accountID: "savings",
                groupID: "cash",
                builder: &builder,
                in: database
            ))
        )

        let renamed = try await AccountGroupSQL.renameAccountGroupMessages(
            groupID: "cash",
            name: "Ready Cash",
            builder: &builder,
            in: database
        )
        #expect(renamed.map(\.column) == ["name"])
        _ = try await database.commitLocalSyncMessagesAndEnqueue(renamed)

        let moved = try await AccountGroupSQL.moveAccountToGroupMessages(
            accountID: "checking",
            groupID: "credit",
            builder: &builder,
            in: database
        )
        #expect(moved.map(\.dataset) == ["accounts"])
        #expect(moved.map(\.column) == ["account_group_id"])
        _ = try await database.commitLocalSyncMessagesAndEnqueue(moved)

        let ungrouped = try await AccountGroupSQL.moveAccountToGroupMessages(
            accountID: "checking",
            groupID: nil,
            builder: &builder,
            in: database
        )
        #expect(ungrouped.first?.serializedValue == LocalFirstSyncValue.null.serialized)
        _ = try await database.commitLocalSyncMessagesAndEnqueue(ungrouped)

        let deleted = try await AccountGroupSQL.deleteAccountGroupMessages(
            groupID: "credit",
            builder: &builder,
            in: database
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(deleted)

        let groups = try await AccountGroupSQL.fetchAccountGroups(in: database)
        let accounts = Dictionary(
            uniqueKeysWithValues: try await AccountSQL.fetchAccounts(in: database).map { ($0.id, $0) }
        )
        #expect(groups.map(\.id) == ["cash"])
        #expect(groups.first?.name == "Ready Cash")
        #expect(accounts["checking"]?.accountGroupId == nil)
        #expect(accounts["savings"]?.accountGroupId == "cash")
    }

    @Test func reorderAccountGroupsUsesMidpointSortOrders() async throws {
        let database = try makeWritableAccountGroupDatabase()
        var builder = LocalFirstSyncMessageBuilder()
        for (id, name) in [("a", "A"), ("b", "B"), ("c", "C")] {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(
                try await AccountGroupSQL.createAccountGroupMessages(groupID: id, name: name, builder: &builder, in: database)
            )
        }

        let moved = try await AccountGroupSQL.moveAccountGroupMessages(
            groupID: "c",
            beforeGroupID: "a",
            builder: &builder,
            in: database
        )
        #expect(moved.allSatisfy { $0.dataset == "account_groups" && $0.column == "sort_order" })
        _ = try await database.commitLocalSyncMessagesAndEnqueue(moved)

        #expect(try await AccountGroupSQL.fetchAccountGroups(in: database).map(\.id) == ["c", "a", "b"])
        #expect(try await AccountGroupSQL.fetchAccountGroups(in: database).first?.sortOrder == 8_192)
    }

    @Test func storeCreatesAccountGroupWhenMigrationIsPresent() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(
            additionalFixtureSQL: Self.accountGroupMigrationSQL
        )
        await bundle.store.warmLaunchCaches(budgetID: "group-1")

        try await bundle.store.createAccountGroupAndRefresh(budgetID: "group-1", name: "Cash")
        let groups = bundle.store.accountGroups(budgetID: "group-1")
        let pending = try await bundle.store.database?.pendingLocalSyncMessages() ?? []

        #expect(groups.map(\.name) == ["Cash"])
        #expect(pending.contains { $0.message.dataset == "account_groups" })
        #expect(!pending.contains { $0.message.dataset == "accounts" })
    }

    @Test func shoveSortOrdersMatchesActualMidpointAndAppend() {
        let items = [
            ActualSortOrder.Item(id: "a", sortOrder: 16_384),
            ActualSortOrder.Item(id: "b", sortOrder: 32_768),
            ActualSortOrder.Item(id: "c", sortOrder: 49_152)
        ]
        let beforeA = ActualSortOrder.shove(items: items, targetID: "a")
        #expect(beforeA.sortOrder == 8_192)
        #expect(beforeA.updates.isEmpty)

        let append = ActualSortOrder.shove(items: items, targetID: nil)
        #expect(append.sortOrder == 65_536)
        #expect(append.updates.isEmpty)
    }

    @Test func shoveSortOrdersHandlesEmptyAndCrowdedGaps() {
        #expect(ActualSortOrder.shove(items: [], targetID: nil).sortOrder == 16_384)

        let crowded = [
            ActualSortOrder.Item(id: "a", sortOrder: 1),
            ActualSortOrder.Item(id: "b", sortOrder: 2),
            ActualSortOrder.Item(id: "c", sortOrder: 3)
        ]
        let result = ActualSortOrder.shove(items: crowded, targetID: "b")
        #expect(result.sortOrder == 1.5)
        #expect(result.updates == [
            ActualSortOrder.Item(id: "b", sortOrder: 16_386),
            ActualSortOrder.Item(id: "c", sortOrder: 32_770)
        ])
    }

    private func makeWritableAccountGroupDatabase(extraSQL: String = "") throws -> BudgetDatabase {
        try BudgetDatabase(
            databaseURL: try makeSQLiteFixture(extraSQL: """
                \(Self.accountGroupMigrationSQL)
                \(extraSQL)
                """),
            localNodeID: "node1"
        )
    }

    private static let accountGroupMigrationSQL = """
        CREATE TABLE IF NOT EXISTS __migrations__ (id INTEGER PRIMARY KEY);
        INSERT INTO __migrations__ (id) VALUES (1787013118115);
        """
}
