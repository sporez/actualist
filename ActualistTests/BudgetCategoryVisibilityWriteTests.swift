import Foundation
import GRDB
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func categoryAndGroupHideWriteOnlyTheHiddenColumn() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO category_groups VALUES ('hidden-grp', 'Hidden Group', 0, 0, 0, 4);
            INSERT INTO categories VALUES ('secret', 'Secret', 'hidden-grp', 0, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('secret', 'secret');
            INSERT INTO zero_budgets VALUES (202607, 'secret', 4000, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()

        let hideCategory = try await database.setCategoryHiddenMessages(
            categoryID: "groceries",
            hidden: true,
            builder: &builder
        )
        #expect(hideCategory.map(\.column) == ["hidden"])
        #expect(hideCategory.map(\.dataset) == ["categories"])
        #expect(hideCategory.map(\.row) == ["groceries"])
        #expect(hideCategory.map(\.serializedValue) == ["N:1"])
        #expect(try await database.commitLocalSyncMessagesAndEnqueue(hideCategory) == 1)

        let showCategory = try await database.setCategoryHiddenMessages(
            categoryID: "groceries",
            hidden: false,
            builder: &builder
        )
        #expect(showCategory.map(\.serializedValue) == ["N:0"])
        #expect(try await database.commitLocalSyncMessagesAndEnqueue(showCategory) == 1)

        let hideGroup = try await database.setCategoryGroupHiddenMessages(
            groupID: "hidden-grp",
            hidden: true,
            builder: &builder
        )
        #expect(hideGroup.map(\.dataset) == ["category_groups"])
        #expect(hideGroup.map(\.column) == ["hidden"])
        #expect(hideGroup.map(\.row) == ["hidden-grp"])
        #expect(try await database.commitLocalSyncMessagesAndEnqueue(hideGroup) == 1)

        let month = try await database.fetchBudgetMonth(month: "2026-07")
        let secret = try #require(month.categoryGroups.first { $0.id == "hidden-grp" }?.categories.first)
        #expect(month.categoryGroups.first { $0.id == "hidden-grp" }?.hidden == true)
        #expect(secret.hidden == false)
        #expect(month.categoryGroups.first { $0.id == "group" }?.categories.first { $0.id == "groceries" }?.hidden == false)
    }

    @Test func groupHideDoesNotWriteChildRows() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.setCategoryGroupHiddenMessages(
            groupID: "group",
            hidden: true,
            builder: &builder
        )
        #expect(messages.count == 1)
        #expect(messages.first?.dataset == "category_groups")
        #expect(messages.first?.row == "group")
    }

    @Test func incomeGroupHideIsRejected() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO category_groups VALUES ('income-grp', 'Income', 1, 0, 0, 3);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()
        await #expect(throws: LocalFirstError.invalidLocalWrite("income groups cannot be hidden")) {
            _ = try await database.setCategoryGroupHiddenMessages(
                groupID: "income-grp",
                hidden: true,
                builder: &builder
            )
        }
    }

    @Test func categoryHideInAHiddenGroupIsRejected() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO category_groups VALUES ('hidden-grp', 'Hidden Group', 0, 1, 0, 4);
            INSERT INTO categories VALUES ('secret', 'Secret', 'hidden-grp', 0, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('secret', 'secret');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()
        await #expect(throws: LocalFirstError.invalidLocalWrite("cannot change a category in a hidden group")) {
            _ = try await database.setCategoryHiddenMessages(
                categoryID: "secret",
                hidden: true,
                builder: &builder
            )
        }
    }

    @Test func missingHiddenColumnFailsClosed() async throws {
        let url = try makeCategoryGroupsWithoutHiddenColumnFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()
        await #expect(throws: LocalFirstError.invalidLocalWrite("missing column category_groups.hidden")) {
            _ = try await database.setCategoryGroupHiddenMessages(
                groupID: "group",
                hidden: true,
                builder: &builder
            )
        }
    }

    @Test func inboundWebHiddenMessageAppliesThroughGenericCRDT() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let appliedCount = try await database.applyRemoteSyncMessages([
            ActualSyncDecodedMessage(
                timestamp: "2026-07-01T12:00:00.000Z-0000-remote",
                dataset: "category_groups",
                row: "group",
                column: "hidden",
                serializedValue: "N:1"
            )
        ])
        #expect(appliedCount == 1)
        let month = try await database.fetchBudgetMonth(month: "2026-07")
        #expect(month.categoryGroups.first { $0.id == "group" }?.hidden == true)
        #expect(month.categoryGroups.first { $0.id == "group" }?.categories.first?.hidden == false)
    }

    @Test func hidingAFundedCategoryLeavesToBudgetUnchanged() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let before = try await bundle.store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let after = try await bundle.store.setCategoryHiddenAndRefresh(
            categoryID: "groceries",
            hidden: true,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        #expect(after.month.toBudget == before.month.toBudget)
        #expect(after.month.totalBudgeted == before.month.totalBudgeted)
        #expect(after.month.categoryGroups.first { $0.id == "group" }?.categories.first { $0.id == "groceries" }?.hidden == true)
    }

    func makeCategoryGroupsWithoutHiddenColumnFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ActualistTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "db.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE category_groups (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    is_income INTEGER,
                    tombstone INTEGER
                );
                CREATE TABLE messages_crdt (
                    timestamp TEXT,
                    dataset TEXT,
                    row TEXT,
                    column TEXT,
                    value TEXT
                );
                INSERT INTO category_groups VALUES ('group', 'Everyday', 0, 0);
                """)
        }
        return url
    }
}
