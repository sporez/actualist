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

    @Test func storeCategoryLifecycleReloadsWithSnakeCaseMappingColumn() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: """
            ALTER TABLE category_mapping RENAME COLUMN transferId TO transfer_id;
            """)

        let loaded = try await bundle.store.createCategoryAndRefresh(
            name: "Fuel",
            groupID: "group",
            budgetID: "group-1",
            month: "2026-07"
        )

        #expect(loaded.month.categoryGroups.flatMap(\.categories).contains { $0.name == "Fuel" })
        #expect(loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }?.spent == -12345)
        let transactions = try await bundle.store.database?.fetchTransactions() ?? []
        #expect(transactions.first { $0.id == "txn" }?.category == "groceries")
    }

    @Test func categoryNeedsTransferUsesMappedTransactionsBudgetAmountsAndDirectFallback() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO categories VALUES ('mapped', 'Mapped', 'group', 0, 0, 0, 2);
            INSERT INTO categories VALUES ('funded', 'Funded', 'group', 0, 0, 0, 3);
            INSERT INTO categories VALUES ('clean', 'Clean', 'group', 0, 0, 0, 4);
            INSERT INTO category_mapping VALUES ('mapped', 'groceries');
            INSERT INTO category_mapping VALUES ('funded', 'funded');
            INSERT INTO category_mapping VALUES ('clean', 'clean');
            INSERT INTO zero_budgets VALUES (202607, 'funded', 1, 0);
            INSERT INTO zero_budgets VALUES (202607, 'clean', 0, 0);
            UPDATE transactions SET category = 'mapped' WHERE id = 'txn';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")

        #expect(try await database.categoryNeedsTransfer(categoryID: "groceries"))
        #expect(try await database.categoryNeedsTransfer(categoryID: "funded"))
        #expect(try await !database.categoryNeedsTransfer(categoryID: "clean"))

        let queue = try DatabaseQueue(path: fixtureURL.path)
        try await queue.write { db in try db.execute(sql: "DROP TABLE category_mapping") }
        let fallbackDatabase = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node2")
        #expect(try await fallbackDatabase.categoryNeedsTransfer(categoryID: "mapped"))
    }

    @Test func deleteWithoutTransferWritesOnlyTombstoneAndRemovesCategoryFromReads() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO categories VALUES ('clean', 'Clean', 'group', 0, 0, 0, 2);
            INSERT INTO category_mapping VALUES ('clean', 'clean');
            INSERT INTO zero_budgets VALUES (202607, 'clean', 0, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()

        await #expect(throws: LocalFirstError.invalidLocalWrite("category requires a transfer destination")) {
            _ = try await database.deleteCategoryMessages(
                categoryID: "groceries", transferCategoryID: nil, builder: &builder
            )
        }

        let messages = try await database.deleteCategoryMessages(
            categoryID: "clean", transferCategoryID: nil, builder: &builder
        )
        #expect(messages.map(\.dataset) == ["categories"])
        #expect(messages.map(\.column) == ["tombstone"])
        #expect(messages.first?.serializedValue == "N:1")
        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)

        let month = try await database.fetchBudgetMonth(month: "2026-07")
        #expect(month.categoryGroups.flatMap(\.categories).contains { $0.id == "clean" } == false)
    }

    @Test func deleteWithTransferMovesEachBudgetMonthForwardsMappingChainAndPreservesReads() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO categories VALUES ('source', 'Source', 'group', 0, 0, 0, 2);
            INSERT INTO categories VALUES ('alias', 'Alias', 'group', 0, 0, 0, 3);
            INSERT INTO categories VALUES ('destination', 'Destination', 'group', 0, 0, 0, 4);
            INSERT INTO category_mapping VALUES ('source', 'source');
            INSERT INTO category_mapping VALUES ('alias', 'source');
            INSERT INTO category_mapping VALUES ('destination', 'destination');
            INSERT INTO zero_budgets VALUES (202607, 'source', 10000, 0);
            INSERT INTO zero_budgets VALUES (202607, 'destination', 2000, 0);
            INSERT INTO zero_budgets VALUES (202608, 'source', 30000, 0);
            INSERT INTO zero_budgets VALUES (202608, 'destination', 4000, 0);
            UPDATE transactions SET category = 'alias' WHERE id = 'txn';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let before = try await database.fetchBudgetMonth(month: "2026-07")
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.deleteCategoryMessages(
            categoryID: "source", transferCategoryID: "destination", builder: &builder
        )
        #expect(messages.contains { $0.dataset == "zero_budgets" && $0.row == "202607-destination" && $0.column == "amount" && $0.serializedValue == "N:12000" })
        #expect(messages.contains { $0.dataset == "zero_budgets" && $0.row == "202608-destination" && $0.column == "amount" && $0.serializedValue == "N:34000" })
        #expect(messages.contains { $0.dataset == "category_mapping" && $0.row == "alias" && $0.serializedValue == "S:destination" })
        #expect(messages.contains { $0.dataset == "category_mapping" && $0.row == "source" && $0.serializedValue == "S:destination" })
        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)

        let queue = try DatabaseQueue(path: fixtureURL.path)
        let stored = try await queue.read { db -> (Int, Int, String?, String?) in
            let sourceAmount = try Int.fetchOne(db, sql: "SELECT amount FROM zero_budgets WHERE month = 202607 AND category = 'source'") ?? 0
            let destinationAmount = try Int.fetchOne(db, sql: "SELECT amount FROM zero_budgets WHERE month = 202607 AND category = 'destination'") ?? 0
            let sourceMapping = try String.fetchOne(db, sql: "SELECT transferId FROM category_mapping WHERE id = 'source'")
            let aliasMapping = try String.fetchOne(db, sql: "SELECT transferId FROM category_mapping WHERE id = 'alias'")
            return (sourceAmount, destinationAmount, sourceMapping, aliasMapping)
        }
        #expect(stored.0 == 10000)
        #expect(stored.1 == 12000)
        #expect(stored.2 == "destination")
        #expect(stored.3 == "destination")

        let after = try await database.fetchBudgetMonth(month: "2026-07")
        let destination = try #require(after.categoryGroups.flatMap(\.categories).first { $0.id == "destination" })
        #expect(destination.budgeted == 12000)
        #expect(destination.spent == -12345)
        #expect(after.toBudget == before.toBudget)
        #expect(after.categoryGroups.flatMap(\.categories).contains { $0.id == "source" } == false)
    }

    @Test func transferDeleteSupportsSnakeCaseMappingAndRejectsInvalidDestinationsAndSchema() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 2);
            INSERT INTO categories VALUES ('clean', 'Clean', 'group', 0, 0, 0, 2);
            INSERT INTO categories VALUES ('destination', 'Destination', 'group', 0, 0, 0, 3);
            INSERT INTO categories VALUES ('income', 'Income', 'income', 1, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('clean', 'clean');
            INSERT INTO category_mapping VALUES ('destination', 'destination');
            INSERT INTO category_mapping VALUES ('income', 'income');
            """)
        let queue = try DatabaseQueue(path: fixtureURL.path)
        try await queue.write { db in
            try db.execute(sql: "ALTER TABLE category_mapping RENAME COLUMN transferId TO transfer_id")
        }
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.deleteCategoryMessages(
            categoryID: "clean", transferCategoryID: "destination", builder: &builder
        )
        #expect(messages.contains { $0.dataset == "category_mapping" && $0.column == "transfer_id" })
        await #expect(throws: LocalFirstError.invalidLocalWrite("income and expense categories cannot be mixed")) {
            _ = try await database.deleteCategoryMessages(
                categoryID: "clean", transferCategoryID: "income", builder: &builder
            )
        }
        await #expect(throws: LocalFirstError.invalidLocalWrite("category no longer exists")) {
            _ = try await database.deleteCategoryMessages(
                categoryID: "clean", transferCategoryID: "missing", builder: &builder
            )
        }

        try await queue.write { db in try db.execute(sql: "DROP TABLE category_mapping") }
        let missingMappingDatabase = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node2")
        await #expect(throws: LocalFirstError.invalidLocalWrite("missing category_mapping table")) {
            _ = try await missingMappingDatabase.deleteCategoryMessages(
                categoryID: "clean", transferCategoryID: "destination", builder: &builder
            )
        }

        let missingTombstoneURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO categories VALUES ('clean', 'Clean', 'group', 0, 0, 0, 2);
            INSERT INTO category_mapping VALUES ('clean', 'clean');
            """)
        let missingTombstoneQueue = try DatabaseQueue(path: missingTombstoneURL.path)
        try await missingTombstoneQueue.write { db in
            try db.execute(sql: "ALTER TABLE categories DROP COLUMN tombstone")
        }
        let missingTombstoneDatabase = try BudgetDatabase(
            databaseURL: missingTombstoneURL, localNodeID: "node3"
        )
        await #expect(throws: LocalFirstError.invalidLocalWrite("missing column categories.tombstone")) {
            _ = try await missingTombstoneDatabase.deleteCategoryMessages(
                categoryID: "clean", transferCategoryID: nil, builder: &builder
            )
        }
    }

    @Test func transferDeleteRejectsBudgetAmountOverflow() async throws {
        let database = try BudgetDatabase(
            databaseURL: try makeSQLiteFixture(extraSQL: """
                INSERT INTO categories VALUES ('source', 'Source', 'group', 0, 0, 0, 2);
                INSERT INTO categories VALUES ('destination', 'Destination', 'group', 0, 0, 0, 3);
                INSERT INTO category_mapping VALUES ('source', 'source');
                INSERT INTO category_mapping VALUES ('destination', 'destination');
                INSERT INTO zero_budgets VALUES (202607, 'source', \(Int.max), 0);
                INSERT INTO zero_budgets VALUES (202607, 'destination', 1, 0);
                """),
            localNodeID: "node1"
        )
        var builder = LocalFirstSyncMessageBuilder()

        await #expect(throws: LocalFirstError.numericValueOutOfRange) {
            _ = try await database.deleteCategoryMessages(
                categoryID: "source", transferCategoryID: "destination", builder: &builder
            )
        }
    }

    @Test func groupDeleteTombstonesEveryChildAndTransfersWithOneExternalDestination() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO category_groups VALUES ('victim', 'Victim', 0, 0, 0, 2);
            INSERT INTO category_groups VALUES ('empty', 'Empty', 0, 0, 0, 3);
            INSERT INTO categories VALUES ('one', 'One', 'victim', 0, 0, 0, 1);
            INSERT INTO categories VALUES ('old', 'Old', 'victim', 0, 0, 1, 2);
            INSERT INTO categories VALUES ('destination', 'Destination', 'group', 0, 0, 0, 2);
            INSERT INTO category_mapping VALUES ('one', 'one');
            INSERT INTO category_mapping VALUES ('old', 'old');
            INSERT INTO category_mapping VALUES ('destination', 'destination');
            INSERT INTO zero_budgets VALUES (202607, 'one', 7000, 0);
            INSERT INTO zero_budgets VALUES (202607, 'old', 9000, 0);
            INSERT INTO zero_budgets VALUES (202607, 'destination', 1000, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()
        let emptyMessages = try await database.deleteCategoryGroupMessages(
            groupID: "empty", transferCategoryID: nil, builder: &builder
        )
        #expect(emptyMessages.map(\.dataset) == ["category_groups"])
        await #expect(throws: LocalFirstError.invalidLocalWrite("category group requires a transfer destination")) {
            _ = try await database.deleteCategoryGroupMessages(
                groupID: "victim", transferCategoryID: nil, builder: &builder
            )
        }

        let messages = try await database.deleteCategoryGroupMessages(
            groupID: "victim", transferCategoryID: "destination", builder: &builder
        )
        #expect(messages.contains { $0.dataset == "categories" && $0.row == "one" && $0.column == "tombstone" })
        #expect(messages.contains { $0.dataset == "categories" && $0.row == "old" && $0.column == "tombstone" })
        #expect(messages.contains { $0.dataset == "category_groups" && $0.row == "victim" && $0.column == "tombstone" })
        #expect(messages.contains { $0.dataset == "zero_budgets" && $0.row == "202607-destination" && $0.serializedValue == "N:8000" })
        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        let month = try await database.fetchBudgetMonth(month: "2026-07")
        #expect(month.categoryGroups.contains { $0.id == "victim" } == false)
        #expect(month.categoryGroups.flatMap(\.categories).contains { $0.id == "one" } == false)
    }

    @Test func inboundWebTransferAndTombstoneApplyGenericallyAndPreserveMoneyReads() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO categories VALUES ('destination', 'Destination', 'group', 0, 0, 0, 2);
            INSERT INTO category_mapping VALUES ('destination', 'destination');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let before = try await database.fetchBudgetMonth(month: "2026-07")
        let messages = [
            ActualSyncDecodedMessage(timestamp: "2026-07-30T12:00:00.000Z-0000-remote", dataset: "zero_budgets", row: "202607-destination", column: "month", serializedValue: "N:202607"),
            ActualSyncDecodedMessage(timestamp: "2026-07-30T12:00:00.001Z-0000-remote", dataset: "zero_budgets", row: "202607-destination", column: "category", serializedValue: "S:destination"),
            ActualSyncDecodedMessage(timestamp: "2026-07-30T12:00:00.002Z-0000-remote", dataset: "zero_budgets", row: "202607-destination", column: "amount", serializedValue: "N:50000"),
            ActualSyncDecodedMessage(timestamp: "2026-07-30T12:00:00.003Z-0000-remote", dataset: "category_mapping", row: "groceries", column: "transferId", serializedValue: "S:destination"),
            ActualSyncDecodedMessage(timestamp: "2026-07-30T12:00:00.004Z-0000-remote", dataset: "categories", row: "groceries", column: "tombstone", serializedValue: "N:1")
        ]
        #expect(try await database.applyRemoteSyncMessages(messages) == messages.count)

        let after = try await database.fetchBudgetMonth(month: "2026-07")
        let destination = try #require(after.categoryGroups.flatMap(\.categories).first { $0.id == "destination" })
        #expect(destination.budgeted == 50000)
        #expect(destination.spent == -12345)
        #expect(after.toBudget == before.toBudget)
        #expect(after.categoryGroups.flatMap(\.categories).contains { $0.id == "groceries" } == false)
    }

    @Test func storeDeleteCommitsReloadsAndReturnsRequestedMonth() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: """
            INSERT INTO categories VALUES ('clean-delete', 'Clean Delete', 'group', 0, 0, 0, 20, NULL);
            INSERT INTO category_mapping VALUES ('clean-delete', 'clean-delete');
            INSERT INTO zero_budgets VALUES (202607, 'clean-delete', 0, 0);
            """)
        #expect(try await bundle.store.categoryNeedsTransfer(categoryID: "clean-delete", budgetID: "group-1") == false)
        let loaded = try await bundle.store.deleteCategoryAndRefresh(
            categoryID: "clean-delete", transferCategoryID: nil,
            budgetID: "group-1", month: "2026-07"
        )
        #expect(loaded.selectedMonth == "2026-07")
        let categoryIDs = loaded.month.categoryGroups.flatMap(\.categories).map(\.id)
        #expect(!categoryIDs.contains("clean-delete"))
        let pending = try await bundle.store.database?.pendingLocalSyncMessages() ?? []
        let hasTombstone = pending.contains { pendingMessage in
            let message = pendingMessage.message
            return message.dataset == "categories"
                && message.row == "clean-delete"
                && message.column == "tombstone"
        }
        #expect(hasTombstone)
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

    private func makeOpenedWritableStoreBundle(
        additionalFixtureSQL: String = ""
    ) async throws -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        try await support.makeOpenedWritableStoreBundle(additionalFixtureSQL: additionalFixtureSQL)
    }
}
