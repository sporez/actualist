import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct CategoryLifecycleWriteTests {
    private let support = LocalFirstActualStoreTests()

    @Test func createCategoryTrimsPlacesFirstAndCreatesIdentityMapping() async throws {
        let database = try BudgetDatabase(databaseURL: try makeSQLiteFixture(), localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.createCategoryMessages(
            categoryID: "fuel",
            name: "  Fuel  ",
            groupID: "group",
            builder: &builder
        )
        #expect(messages.contains { $0.dataset == "categories" && $0.column == "name" && $0.serializedValue == "S:Fuel" })
        #expect(messages.contains { $0.dataset == "categories" && $0.column == "sort_order" && $0.serializedValue == "N:0.5" })
        #expect(messages.contains { $0.dataset == "category_mapping" && $0.row == "fuel" && $0.column == "transferId" && $0.serializedValue == "S:fuel" })

        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        let month = try await database.fetchBudgetMonth(month: "2026-07")
        let group = try #require(month.categoryGroups.first { $0.id == "group" })
        #expect(group.categories.map(\.id) == ["fuel", "groceries"])
    }

    @Test func createCategoryRejectsDuplicatesIncomeInEnvelopeAndMissingSchema() async throws {
        let database = try BudgetDatabase(
            databaseURL: try makeSQLiteFixture(extraSQL: "INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 2);"),
            localNodeID: "node1"
        )
        var builder = LocalFirstSyncMessageBuilder()
        await #expect(throws: LocalFirstError.invalidLocalWrite("A category with the name Groceries already exists.")) {
            _ = try await database.createCategoryMessages(categoryID: "copy", name: "groceries", groupID: "group", builder: &builder)
        }
        await #expect(throws: LocalFirstError.invalidLocalWrite("income categories cannot be managed in an envelope budget")) {
            _ = try await database.createCategoryMessages(categoryID: "salary", name: "Salary", groupID: "income", builder: &builder)
        }

        let missingMapping = try BudgetDatabase(databaseURL: try makeCategoryLifecycleFixtureWithoutMapping(), localNodeID: "node1")
        await #expect(throws: LocalFirstError.invalidLocalWrite("missing category_mapping table")) {
            _ = try await missingMapping.createCategoryMessages(categoryID: "fuel", name: "Fuel", groupID: "group", builder: &builder)
        }
    }

    @Test func createCategorySupportsSnakeCaseMappingColumn() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let queue = try DatabaseQueue(path: fixtureURL.path)
        try await queue.write { db in
            try db.execute(sql: "ALTER TABLE category_mapping RENAME COLUMN transferId TO transfer_id")
        }
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.createCategoryMessages(
            categoryID: "fuel", name: "Fuel", groupID: "group", builder: &builder
        )

        #expect(messages.contains {
            $0.dataset == "category_mapping" && $0.column == "transfer_id" && $0.serializedValue == "S:fuel"
        })
    }

    @Test func trackingBudgetAllowsIncomeCategoryAndGroupRenames() async throws {
        let database = try BudgetDatabase(
            databaseURL: try makeSQLiteFixture(extraSQL: """
                CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
                INSERT INTO preferences VALUES ('budgetType', 'tracking');
                INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 2);
                """),
            localNodeID: "node1"
        )
        var builder = LocalFirstSyncMessageBuilder()
        let created = try await database.createCategoryMessages(
            categoryID: "salary", name: "Salary", groupID: "income", builder: &builder
        )
        #expect(created.contains { $0.column == "is_income" && $0.serializedValue == "N:1" })
        let renamed = try await database.renameCategoryGroupMessages(
            groupID: "income", name: "Pay", builder: &builder
        )
        #expect(renamed.first?.serializedValue == "S:Pay")
    }

    @Test func createGroupAppendsAndRejectsEmptyAndHiddenDuplicateNames() async throws {
        let database = try BudgetDatabase(
            databaseURL: try makeSQLiteFixture(extraSQL: "INSERT INTO category_groups VALUES ('hidden', 'Archived', 0, 1, 0, 4);"),
            localNodeID: "node1"
        )
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.createCategoryGroupMessages(groupID: "bills", name: " Bills ", builder: &builder)
        #expect(messages.contains { $0.column == "sort_order" && $0.serializedValue == "N:16388.0" })

        await #expect(throws: LocalFirstError.invalidLocalWrite("category group name cannot be empty")) {
            _ = try await database.createCategoryGroupMessages(groupID: "blank", name: "  ", builder: &builder)
        }
        await #expect(throws: LocalFirstError.invalidLocalWrite("A hidden category group with the name Archived already exists.")) {
            _ = try await database.createCategoryGroupMessages(groupID: "again", name: "archived", builder: &builder)
        }
    }

    @Test func renameCategoryAndGroupTrimNoOpAndEnforceUniqueNames() async throws {
        let database = try BudgetDatabase(
            databaseURL: try makeSQLiteFixture(extraSQL: """
                INSERT INTO category_groups VALUES ('bills', 'Bills', 0, 0, 0, 2);
                INSERT INTO categories VALUES ('fuel', 'Fuel', 'group', 0, 0, 0, 2);
                INSERT INTO category_mapping VALUES ('fuel', 'fuel');
                """),
            localNodeID: "node1"
        )
        var builder = LocalFirstSyncMessageBuilder()
        #expect(try await database.renameCategoryMessages(categoryID: "fuel", name: " Fuel ", builder: &builder).isEmpty)
        #expect(try await database.renameCategoryGroupMessages(groupID: "bills", name: " Bills ", builder: &builder).isEmpty)
        let category = try await database.renameCategoryMessages(categoryID: "fuel", name: " Transport ", builder: &builder)
        #expect(category.map(\.column) == ["name"])
        #expect(category.first?.serializedValue == "S:Transport")
        await #expect(throws: LocalFirstError.invalidLocalWrite("A category with the name Groceries already exists.")) {
            _ = try await database.renameCategoryMessages(categoryID: "fuel", name: "groceries", builder: &builder)
        }
        await #expect(throws: LocalFirstError.invalidLocalWrite("A category group with the name Everyday already exists.")) {
            _ = try await database.renameCategoryGroupMessages(groupID: "bills", name: "everyday", builder: &builder)
        }
    }

    @Test func outlineWritesIntraAndCrossGroupChangesAndRejectsInvalidMoves() async throws {
        let database = try BudgetDatabase(
            databaseURL: try makeSQLiteFixture(extraSQL: """
                INSERT INTO category_groups VALUES ('bills', 'Bills', 0, 0, 0, 2);
                INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 3);
                INSERT INTO categories VALUES ('fuel', 'Fuel', 'group', 0, 0, 0, 2);
                INSERT INTO categories VALUES ('rent', 'Rent', 'bills', 0, 0, 0, 1);
                INSERT INTO categories VALUES ('salary', 'Salary', 'income', 1, 0, 0, 1);
                INSERT INTO category_mapping VALUES ('fuel', 'fuel');
                INSERT INTO category_mapping VALUES ('rent', 'rent');
                INSERT INTO category_mapping VALUES ('salary', 'salary');
                """),
            localNodeID: "node1"
        )
        var builder = LocalFirstSyncMessageBuilder()
        let unchanged = BudgetCategoryOutlineCommand(groups: [
            .init(id: "group", categoryIDs: ["groceries", "fuel"]),
            .init(id: "bills", categoryIDs: ["rent"])
        ])
        #expect(try await database.applyCategoryOutlineMessages(unchanged, builder: &builder).isEmpty)
        let command = BudgetCategoryOutlineCommand(groups: [
            .init(id: "bills", categoryIDs: ["fuel", "rent"]),
            .init(id: "group", categoryIDs: ["groceries"])
        ])
        let messages = try await database.applyCategoryOutlineMessages(command, builder: &builder)
        #expect(messages.contains { $0.dataset == "category_groups" && $0.row == "bills" && $0.column == "sort_order" })
        #expect(messages.contains { $0.dataset == "categories" && $0.row == "fuel" && $0.column == "cat_group" && $0.serializedValue == "S:bills" })
        #expect(messages.contains { $0.dataset == "categories" && $0.row == "rent" && $0.column == "sort_order" && $0.serializedValue == "N:32768.0" })

        let stale = BudgetCategoryOutlineCommand(groups: [.init(id: "bills", categoryIDs: ["missing"])])
        await #expect(throws: LocalFirstError.invalidLocalWrite("the category outline changed before it could be saved")) {
            _ = try await database.applyCategoryOutlineMessages(stale, builder: &builder)
        }
        let trackingDatabase = try BudgetDatabase(
            databaseURL: try makeSQLiteFixture(extraSQL: """
                CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
                INSERT INTO preferences VALUES ('budgetType', 'tracking');
                INSERT INTO category_groups VALUES ('bills', 'Bills', 0, 0, 0, 2);
                INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 3);
                INSERT INTO categories VALUES ('fuel', 'Fuel', 'group', 0, 0, 0, 2);
                INSERT INTO categories VALUES ('rent', 'Rent', 'bills', 0, 0, 0, 1);
                INSERT INTO categories VALUES ('salary', 'Salary', 'income', 1, 0, 0, 1);
                """),
            localNodeID: "node1"
        )
        let incomeMove = BudgetCategoryOutlineCommand(groups: [
            .init(id: "group", categoryIDs: ["groceries", "salary"]),
            .init(id: "bills", categoryIDs: ["fuel", "rent"]),
            .init(id: "income", categoryIDs: [])
        ])
        await #expect(throws: LocalFirstError.invalidLocalWrite("income and expense categories cannot be mixed")) {
            _ = try await trackingDatabase.applyCategoryOutlineMessages(incomeMove, builder: &builder)
        }
    }

    @Test func storeCategoryLifecycleCommitsReloadsAndReturnsTheRequestedMonth() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let loaded = try await bundle.store.createCategoryAndRefresh(
            name: "Fuel",
            groupID: "group",
            budgetID: "group-1",
            month: "2026-07"
        )
        #expect(loaded.selectedMonth == "2026-07")
        let group = loaded.month.categoryGroups.first { $0.id == "group" }
        #expect(group?.categories.contains { $0.name == "Fuel" } == true)
        let pending = try await bundle.store.database?.pendingLocalSyncMessages() ?? []
        #expect(pending.contains { $0.message.dataset == "category_mapping" })
    }

    private func makeCategoryLifecycleFixtureWithoutMapping() throws -> URL {
        let url = try makeSQLiteFixture()
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in try db.execute(sql: "DROP TABLE category_mapping") }
        return url
    }

    private func makeSQLiteFixture(extraSQL: String = "") throws -> URL {
        try support.makeSQLiteFixture(extraSQL: extraSQL)
    }

    private func makeOpenedWritableStoreBundle() async throws -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        try await support.makeOpenedWritableStoreBundle()
    }
}
