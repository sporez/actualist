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

        let messages = try await CategorySQL.createCategoryMessages(
            categoryID: "fuel",
            name: "  Fuel  ",
            groupID: "group",
            builder: &builder,
            in: database
        )
        #expect(messages.contains { $0.dataset == "categories" && $0.column == "name" && $0.serializedValue == "S:Fuel" })
        #expect(messages.contains { $0.dataset == "categories" && $0.column == "sort_order" && $0.serializedValue == "N:0.5" })
        #expect(messages.contains { $0.dataset == "category_mapping" && $0.row == "fuel" && $0.column == "transferId" && $0.serializedValue == "S:fuel" })

        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        let month = try await BudgetMonthSQL.fetchBudgetMonth(month: "2026-07", in: database)
        let group = try #require(month.categoryGroups.first { $0.id == "group" })
        #expect(group.categories.map(\.id) == ["fuel", "groceries"])
    }

    @Test func createCategoryRejectsDuplicatesIncomeInEnvelopeAndMissingSchema() async throws {
        let database = try BudgetDatabase(
            databaseURL: try makeSQLiteFixture(extraSQL: "INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 2);"),
            localNodeID: "node1"
        )
        var builder = LocalFirstSyncMessageBuilder()
        await #expect(throws: LocalFirstError.refusedChange("A category with the name Groceries already exists.")) {
            _ = try await CategorySQL.createCategoryMessages(categoryID: "copy", name: "groceries", groupID: "group", builder: &builder, in: database)
        }
        await #expect(throws: LocalFirstError.invalidLocalWrite("income categories cannot be managed in an envelope budget")) {
            _ = try await CategorySQL.createCategoryMessages(categoryID: "salary", name: "Salary", groupID: "income", builder: &builder, in: database)
        }

        let missingMapping = try BudgetDatabase(databaseURL: try makeCategoryLifecycleFixtureWithoutMapping(), localNodeID: "node1")
        await #expect(throws: LocalFirstError.schemaUnavailable("missing category_mapping table")) {
            _ = try await CategorySQL.createCategoryMessages(categoryID: "fuel", name: "Fuel", groupID: "group", builder: &builder, in: missingMapping)
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

        let messages = try await CategorySQL.createCategoryMessages(
            categoryID: "fuel", name: "Fuel", groupID: "group", builder: &builder,
            in: database
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
        let created = try await CategorySQL.createCategoryMessages(
            categoryID: "salary", name: "Salary", groupID: "income", builder: &builder,
            in: database
        )
        #expect(created.contains { $0.column == "is_income" && $0.serializedValue == "N:1" })
        let renamed = try await CategorySQL.renameCategoryGroupMessages(
            groupID: "income", name: "Pay", builder: &builder,
            in: database
        )
        #expect(renamed.first?.serializedValue == "S:Pay")
    }

    @Test func createGroupAppendsAndRejectsEmptyAndHiddenDuplicateNames() async throws {
        let database = try BudgetDatabase(
            databaseURL: try makeSQLiteFixture(extraSQL: "INSERT INTO category_groups VALUES ('hidden', 'Archived', 0, 1, 0, 4);"),
            localNodeID: "node1"
        )
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await CategorySQL.createCategoryGroupMessages(groupID: "bills", name: " Bills ", builder: &builder, in: database)
        #expect(messages.contains { $0.column == "sort_order" && $0.serializedValue == "N:16388.0" })

        await #expect(throws: LocalFirstError.invalidLocalWrite("category group name cannot be empty")) {
            _ = try await CategorySQL.createCategoryGroupMessages(groupID: "blank", name: "  ", builder: &builder, in: database)
        }
        await #expect(throws: LocalFirstError.refusedChange("A hidden category group with the name Archived already exists.")) {
            _ = try await CategorySQL.createCategoryGroupMessages(groupID: "again", name: "archived", builder: &builder, in: database)
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
        #expect(try await CategorySQL.renameCategoryMessages(categoryID: "fuel", name: " Fuel ", builder: &builder, in: database).isEmpty)
        #expect(try await CategorySQL.renameCategoryGroupMessages(groupID: "bills", name: " Bills ", builder: &builder, in: database).isEmpty)
        let category = try await CategorySQL.renameCategoryMessages(categoryID: "fuel", name: " Transport ", builder: &builder, in: database)
        #expect(category.map(\.column) == ["name"])
        #expect(category.first?.serializedValue == "S:Transport")
        await #expect(throws: LocalFirstError.refusedChange("A category with the name Groceries already exists.")) {
            _ = try await CategorySQL.renameCategoryMessages(categoryID: "fuel", name: "groceries", builder: &builder, in: database)
        }
        await #expect(throws: LocalFirstError.refusedChange("A category group with the name Everyday already exists.")) {
            _ = try await CategorySQL.renameCategoryGroupMessages(groupID: "bills", name: "everyday", builder: &builder, in: database)
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
        ], moves: [])
        #expect(try await CategorySQL.applyCategoryOutlineMessages(unchanged, builder: &builder, in: database).isEmpty)
        let command = BudgetCategoryOutlineCommand(groups: [
            .init(id: "bills", categoryIDs: ["fuel", "rent"]),
            .init(id: "group", categoryIDs: ["groceries"])
        ], moves: [
            .group(id: "bills", beforeGroupID: "group"),
            .category(id: "fuel", toGroupID: "bills", beforeCategoryID: "rent"),
        ])
        let messages = try await CategorySQL.applyCategoryOutlineMessages(command, builder: &builder, in: database)
        #expect(messages.contains { $0.dataset == "category_groups" && $0.row == "bills" && $0.column == "sort_order" })
        #expect(messages.contains { $0.dataset == "categories" && $0.row == "fuel" && $0.column == "cat_group" && $0.serializedValue == "S:bills" })
        #expect(messages.contains { $0.dataset == "categories" && $0.row == "rent" && $0.column == "sort_order" && $0.serializedValue == "N:16385.0" })

        let stale = BudgetCategoryOutlineCommand(groups: [.init(id: "bills", categoryIDs: ["missing"])], moves: [])
        await #expect(throws: LocalFirstError.refusedChange("Your categories changed before this could be saved. Try again.")) {
            _ = try await CategorySQL.applyCategoryOutlineMessages(stale, builder: &builder, in: database)
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
        ], moves: [])
        await #expect(throws: LocalFirstError.refusedChange("Income and expense categories cannot be mixed.")) {
            _ = try await CategorySQL.applyCategoryOutlineMessages(incomeMove, builder: &builder, in: trackingDatabase)
        }
    }

    @Test func outlineReplaysEachDragWithActualsShoveInOrder() async throws {
        let database = try BudgetDatabase(
            databaseURL: try makeSQLiteFixture(extraSQL: """
                INSERT INTO category_groups VALUES ('bills', 'Bills', 0, 0, 0, 2);
                INSERT INTO categories VALUES ('fuel', 'Fuel', 'group', 0, 0, 0, 2);
                INSERT INTO categories VALUES ('rent', 'Rent', 'bills', 0, 0, 0, 1);
                INSERT INTO category_mapping VALUES ('fuel', 'fuel');
                INSERT INTO category_mapping VALUES ('rent', 'rent');
                """),
            localNodeID: "node1"
        )
        var builder = LocalFirstSyncMessageBuilder()
        // The second drag targets the first drag's new position, so a one-pass renumbering of the final
        // order would write different values than Actual's two shoves.
        let command = BudgetCategoryOutlineCommand(groups: [
            .init(id: "group", categoryIDs: []),
            .init(id: "bills", categoryIDs: ["groceries", "fuel", "rent"]),
        ], moves: [
            .category(id: "fuel", toGroupID: "bills", beforeCategoryID: "rent"),
            .category(id: "groceries", toGroupID: "bills", beforeCategoryID: "fuel"),
        ])
        let messages = try await CategorySQL.applyCategoryOutlineMessages(command, builder: &builder, in: database)
        func value(_ row: String, _ column: String) -> String? {
            messages.last { $0.dataset == "categories" && $0.row == row && $0.column == column }?.serializedValue
        }
        #expect(value("groceries", "sort_order") == "N:0.25")
        #expect(value("fuel", "sort_order") == "N:16384.0")
        #expect(value("rent", "sort_order") == "N:32768.0")
        #expect(value("groceries", "cat_group") == "S:bills")
        #expect(value("fuel", "cat_group") == "S:bills")
        #expect(value("rent", "cat_group") == nil)
        #expect(messages.allSatisfy { $0.dataset == "categories" })
    }

    @Test func feedRowWhoseCategoryWasDeletedReadsAsHavingNoCategory() async throws {
        let database = try BudgetDatabase(
            databaseURL: try makeSQLiteFixture(extraSQL: "UPDATE categories SET tombstone = 1 WHERE id = 'groceries';"),
            localNodeID: "node1"
        )
        let transaction = try #require(try await TransactionReadSQL.fetchTransactions(in: database).first { $0.id == "txn" })
        #expect(transaction.category == nil)
    }

    @Test func fetchCategoryGroupsKeepsIncomeGroupsLast() async throws {
        let database = try BudgetDatabase(
            databaseURL: try makeSQLiteFixture(extraSQL: """
                INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 0.5);
                INSERT INTO category_groups VALUES ('bills', 'Bills', 0, 0, 0, 9);
                """),
            localNodeID: "node1"
        )
        let month = try await BudgetMonthSQL.fetchBudgetMonth(month: "2026-07", in: database)
        #expect(month.categoryGroups.map(\.id) == ["group", "bills", "income"])
    }

    @Test func storeCategoryLifecycleCommitsReloadsAndReturnsTheRequestedMonth() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let loaded = try await bundle.store.categoryLifecycle.createCategoryAndRefresh(
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

        let loaded = try await bundle.store.categoryLifecycle.createCategoryAndRefresh(
            name: "Fuel",
            groupID: "group",
            budgetID: "group-1",
            month: "2026-07"
        )

        #expect(loaded.month.categoryGroups.flatMap(\.categories).contains { $0.name == "Fuel" })
        #expect(loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }?.spent == -12345)
        let transactions = try await TransactionReadSQL.fetchTransactions(in: try #require(bundle.store.database))
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

        #expect(try await CategoryDeletionSQL.categoryNeedsTransfer(categoryID: "groceries", in: database))
        #expect(try await CategoryDeletionSQL.categoryNeedsTransfer(categoryID: "funded", in: database))
        #expect(try await !CategoryDeletionSQL.categoryNeedsTransfer(categoryID: "clean", in: database))

        let queue = try DatabaseQueue(path: fixtureURL.path)
        try await queue.write { db in try db.execute(sql: "DROP TABLE category_mapping") }
        let fallbackDatabase = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node2")
        #expect(try await CategoryDeletionSQL.categoryNeedsTransfer(categoryID: "mapped", in: fallbackDatabase))
    }

    @Test func deleteWithoutTransferWritesOnlyTombstoneAndRemovesCategoryFromReads() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO categories VALUES ('clean', 'Clean', 'group', 0, 0, 0, 2);
            INSERT INTO category_mapping VALUES ('clean', 'clean');
            INSERT INTO zero_budgets VALUES (202607, 'clean', 0, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()

        await #expect(throws: LocalFirstError.refusedChange("Choose a category to move this category's transactions to before deleting it.")) {
            _ = try await CategoryDeletionSQL.deleteCategoryMessages(
                categoryID: "groceries", transferCategoryID: nil, builder: &builder,
                in: database
            )
        }

        let messages = try await CategoryDeletionSQL.deleteCategoryMessages(
            categoryID: "clean", transferCategoryID: nil, builder: &builder,
            in: database
        )
        #expect(messages.map(\.dataset) == ["categories"])
        #expect(messages.map(\.column) == ["tombstone"])
        #expect(messages.first?.serializedValue == "N:1")
        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)

        let month = try await BudgetMonthSQL.fetchBudgetMonth(month: "2026-07", in: database)
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
        let before = try await BudgetMonthSQL.fetchBudgetMonth(month: "2026-07", in: database)
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await CategoryDeletionSQL.deleteCategoryMessages(
            categoryID: "source", transferCategoryID: "destination", builder: &builder,
            in: database
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

        let after = try await BudgetMonthSQL.fetchBudgetMonth(month: "2026-07", in: database)
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
        let messages = try await CategoryDeletionSQL.deleteCategoryMessages(
            categoryID: "clean", transferCategoryID: "destination", builder: &builder,
            in: database
        )
        #expect(messages.contains { $0.dataset == "category_mapping" && $0.column == "transfer_id" })
        await #expect(throws: LocalFirstError.refusedChange("Income and expense categories cannot be mixed.")) {
            _ = try await CategoryDeletionSQL.deleteCategoryMessages(
                categoryID: "clean", transferCategoryID: "income", builder: &builder,
                in: database
            )
        }
        await #expect(throws: LocalFirstError.invalidLocalWrite("category no longer exists")) {
            _ = try await CategoryDeletionSQL.deleteCategoryMessages(
                categoryID: "clean", transferCategoryID: "missing", builder: &builder,
                in: database
            )
        }

        try await queue.write { db in try db.execute(sql: "DROP TABLE category_mapping") }
        let missingMappingDatabase = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node2")
        await #expect(throws: LocalFirstError.schemaUnavailable("missing category_mapping table")) {
            _ = try await CategoryDeletionSQL.deleteCategoryMessages(
                categoryID: "clean", transferCategoryID: "destination", builder: &builder,
                in: missingMappingDatabase
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
        await #expect(throws: LocalFirstError.schemaUnavailable("missing column categories.tombstone")) {
            _ = try await CategoryDeletionSQL.deleteCategoryMessages(
                categoryID: "clean", transferCategoryID: nil, builder: &builder,
                in: missingTombstoneDatabase
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
            _ = try await CategoryDeletionSQL.deleteCategoryMessages(
                categoryID: "source", transferCategoryID: "destination", builder: &builder,
                in: database
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
        let emptyMessages = try await CategoryDeletionSQL.deleteCategoryGroupMessages(
            groupID: "empty", transferCategoryID: nil, builder: &builder,
            in: database
        )
        #expect(emptyMessages.map(\.dataset) == ["category_groups"])
        await #expect(throws: LocalFirstError.refusedChange("Choose a category to move this group's transactions to before deleting it.")) {
            _ = try await CategoryDeletionSQL.deleteCategoryGroupMessages(
                groupID: "victim", transferCategoryID: nil, builder: &builder,
                in: database
            )
        }

        let messages = try await CategoryDeletionSQL.deleteCategoryGroupMessages(
            groupID: "victim", transferCategoryID: "destination", builder: &builder,
            in: database
        )
        #expect(messages.contains { $0.dataset == "categories" && $0.row == "one" && $0.column == "tombstone" })
        #expect(messages.contains { $0.dataset == "categories" && $0.row == "old" && $0.column == "tombstone" })
        #expect(messages.contains { $0.dataset == "category_groups" && $0.row == "victim" && $0.column == "tombstone" })
        #expect(messages.contains { $0.dataset == "zero_budgets" && $0.row == "202607-destination" && $0.serializedValue == "N:8000" })
        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        let month = try await BudgetMonthSQL.fetchBudgetMonth(month: "2026-07", in: database)
        #expect(month.categoryGroups.contains { $0.id == "victim" } == false)
        #expect(month.categoryGroups.flatMap(\.categories).contains { $0.id == "one" } == false)
    }

    @Test func inboundWebTransferAndTombstoneApplyGenericallyAndPreserveMoneyReads() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO categories VALUES ('destination', 'Destination', 'group', 0, 0, 0, 2);
            INSERT INTO category_mapping VALUES ('destination', 'destination');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let before = try await BudgetMonthSQL.fetchBudgetMonth(month: "2026-07", in: database)
        let messages = [
            ActualSyncDecodedMessage(timestamp: "2026-07-30T12:00:00.000Z-0000-remote", dataset: "zero_budgets", row: "202607-destination", column: "month", serializedValue: "N:202607"),
            ActualSyncDecodedMessage(timestamp: "2026-07-30T12:00:00.001Z-0000-remote", dataset: "zero_budgets", row: "202607-destination", column: "category", serializedValue: "S:destination"),
            ActualSyncDecodedMessage(timestamp: "2026-07-30T12:00:00.002Z-0000-remote", dataset: "zero_budgets", row: "202607-destination", column: "amount", serializedValue: "N:50000"),
            ActualSyncDecodedMessage(timestamp: "2026-07-30T12:00:00.003Z-0000-remote", dataset: "category_mapping", row: "groceries", column: "transferId", serializedValue: "S:destination"),
            ActualSyncDecodedMessage(timestamp: "2026-07-30T12:00:00.004Z-0000-remote", dataset: "categories", row: "groceries", column: "tombstone", serializedValue: "N:1")
        ]
        #expect(try await database.applyRemoteSyncMessages(messages) == messages.count)

        let after = try await BudgetMonthSQL.fetchBudgetMonth(month: "2026-07", in: database)
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
        #expect(try await bundle.store.categoryLifecycle.categoryNeedsTransfer(categoryID: "clean-delete", budgetID: "group-1") == false)
        let loaded = try await bundle.store.categoryLifecycle.deleteCategoryAndRefresh(
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
