import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func accountGroupManagementIsOnAfterOldBudgetBackfill() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")

        #expect(try await database.accountGroupManagementEnabled())
        #expect(try sqliteTables(at: fixtureURL).contains("account_groups"))
    }

    @Test func createAccountGroupAppendsSortOrderAndRejectsDuplicates() async throws {
        let database = try makeWritableAccountGroupDatabase()
        var builder = LocalFirstSyncMessageBuilder()

        let created = try await database.createAccountGroupMessages(
            groupID: "cash",
            name: "Cash",
            builder: &builder
        )
        #expect(try await database.commitLocalSyncMessagesAndEnqueue(created) == created.count)

        let groups = try await database.fetchAccountGroups()
        #expect(groups.map(\.id) == ["cash"])
        #expect(groups.first?.name == "Cash")
        #expect(groups.first?.sortOrder == 16_384)

        await #expect(
            throws: LocalFirstError.invalidLocalWrite("An 'Cash' account group already exists.")
        ) {
            _ = try await database.createAccountGroupMessages(
                groupID: "cash-2",
                name: "cash",
                builder: &builder
            )
        }
    }

    @Test func createAccountGroupReusesATombstonedNameWithANewID() async throws {
        let database = try makeWritableAccountGroupDatabase()
        var builder = LocalFirstSyncMessageBuilder()
        let created = try await database.createAccountGroupMessages(
            groupID: "cash",
            name: "Cash",
            builder: &builder
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(created)
        let deleted = try await database.deleteAccountGroupMessages(
            groupID: "cash",
            builder: &builder
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(deleted)

        let recreated = try await database.createAccountGroupMessages(
            groupID: "cash-new",
            name: "Cash",
            builder: &builder
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(recreated)
        let groups = try await database.fetchAccountGroups()
        #expect(groups.map(\.id) == ["cash-new"])
    }

    @Test func renameMoveUngroupAndDeleteAccountGroupsWritePerColumnMessages() async throws {
        let database = try makeWritableAccountGroupDatabase(
            extraSQL: "INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0, 2);"
        )
        var builder = LocalFirstSyncMessageBuilder()
        _ = try await database.commitLocalSyncMessagesAndEnqueue(
            try await database.createAccountGroupMessages(groupID: "cash", name: "Cash", builder: &builder)
            + (try await database.createAccountGroupMessages(groupID: "credit", name: "Credit", builder: &builder))
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(
            try await database.moveAccountToGroupMessages(
                accountID: "checking",
                groupID: "cash",
                builder: &builder
            )
            + (try await database.moveAccountToGroupMessages(
                accountID: "savings",
                groupID: "cash",
                builder: &builder
            ))
        )

        let renamed = try await database.renameAccountGroupMessages(
            groupID: "cash",
            name: "Ready Cash",
            builder: &builder
        )
        #expect(renamed.map(\.column) == ["name"])
        _ = try await database.commitLocalSyncMessagesAndEnqueue(renamed)

        let moved = try await database.moveAccountToGroupMessages(
            accountID: "checking",
            groupID: "credit",
            builder: &builder
        )
        #expect(moved.map(\.dataset) == ["accounts"])
        #expect(moved.map(\.column) == ["account_group_id"])
        _ = try await database.commitLocalSyncMessagesAndEnqueue(moved)

        let ungrouped = try await database.moveAccountToGroupMessages(
            accountID: "checking",
            groupID: nil,
            builder: &builder
        )
        #expect(ungrouped.first?.serializedValue == LocalFirstSyncValue.null.serialized)
        _ = try await database.commitLocalSyncMessagesAndEnqueue(ungrouped)

        let deleted = try await database.deleteAccountGroupMessages(
            groupID: "credit",
            builder: &builder
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(deleted)

        let groups = try await database.fetchAccountGroups()
        let accounts = Dictionary(
            uniqueKeysWithValues: try await database.fetchAccounts().map { ($0.id, $0) }
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
                try await database.createAccountGroupMessages(groupID: id, name: name, builder: &builder)
            )
        }

        let moved = try await database.moveAccountGroupMessages(
            groupID: "c",
            beforeGroupID: "a",
            builder: &builder
        )
        #expect(moved.allSatisfy { $0.dataset == "account_groups" && $0.column == "sort_order" })
        _ = try await database.commitLocalSyncMessagesAndEnqueue(moved)

        #expect(try await database.fetchAccountGroups().map(\.id) == ["c", "a", "b"])
        #expect(try await database.fetchAccountGroups().first?.sortOrder == 8_192)
    }

    @Test func storeCreatesAccountGroupWhenMigrationIsPresent() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(
            additionalFixtureSQL: Self.accountGroupMigrationSQL
        )
        #expect(bundle.store.accountGroupManagementEnabled(budgetID: "group-1"))

        try await bundle.store.createAccountGroupAndRefresh(budgetID: "group-1", name: "Cash")
        let groups = bundle.store.accountGroups(budgetID: "group-1")
        let pending = try await bundle.store.database?.pendingLocalSyncMessages() ?? []

        #expect(groups.map(\.name) == ["Cash"])
        #expect(pending.contains { $0.message.dataset == "account_groups" })
        #expect(!pending.contains { $0.message.dataset == "accounts" })
    }

    @Test func shoveSortOrdersMatchesActualMidpointAndAppend() {
        let items = [
            AccountGroupSort.Item(id: "a", sortOrder: 16_384),
            AccountGroupSort.Item(id: "b", sortOrder: 32_768),
            AccountGroupSort.Item(id: "c", sortOrder: 49_152)
        ]
        let beforeA = AccountGroupSort.shove(items: items, targetID: "a")
        #expect(beforeA.sortOrder == 8_192)
        #expect(beforeA.updates.isEmpty)

        let append = AccountGroupSort.shove(items: items, targetID: nil)
        #expect(append.sortOrder == 65_536)
        #expect(append.updates.isEmpty)
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
