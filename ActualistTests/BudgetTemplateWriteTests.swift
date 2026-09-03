import Foundation
import GRDB
import Testing
@testable import Actualist

@Suite("Budget template writes")
@MainActor
struct BudgetTemplateWriteTests {
    private let fixtures = LocalFirstActualStoreTests()

    private func makeSQLiteFixture(extraSQL: String = "") throws -> URL {
        try fixtures.makeSQLiteFixture(extraSQL: extraSQL)
    }

    private func makeOpenedWritableStoreBundle(
        additionalFixtureSQL: String = ""
    ) async throws -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        try await fixtures.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: additionalFixtureSQL
        )
    }
    @Test func templateWriteSetsGoalDefAndUISourceWithoutApplyingBudget() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let json = try BudgetTemplateDefinition.encode([
            .monthlyFixed(amount: 400, now: Self.templateWriteNow),
            .remainder()
        ])
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.setCategoryTemplateMessages(
            categoryID: "groceries",
            goalDefJSON: json,
            builder: &builder
        )
        #expect(Set(messages.map(\.dataset)) == ["categories"])
        #expect(Set(messages.map(\.row)) == ["groceries"])
        #expect(Set(messages.map(\.column)) == ["goal_def", "template_settings"])
        #expect(
            messages.first { $0.column == "template_settings" }?.serializedValue
                == "S:\(BudgetDatabase.uiTemplateSettingsJSON)"
        )
        #expect(messages.contains { $0.column == "goal_def" && $0.serializedValue.hasPrefix("S:") })
        #expect(!messages.contains { $0.dataset == "zero_budgets" })

        #expect(try await database.commitLocalSyncMessagesAndEnqueue(messages) == 2)
        let stored = try categoryTemplateState("groceries", at: fixtureURL)
        #expect(stored.goalDef == json)
        #expect(stored.settings == BudgetDatabase.uiTemplateSettingsJSON)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
        #expect(try await database.pendingLocalSyncMessageCount() == 2)

        let month = try await database.fetchBudgetMonth(month: "2026-07")
        #expect(
            month.categoryGroups.first { $0.id == "group" }?
                .categories.first { $0.id == "groceries" }?
                .hasTemplateDefinition == true
        )
    }

    @Test func templateWriteEmptyListNullsGoalDefAndKeepsUISource() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":400,"priority":1}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.setCategoryTemplateMessages(
            categoryID: "groceries",
            goalDefJSON: nil,
            builder: &builder
        )
        #expect(messages.map(\.column) == ["goal_def"])
        #expect(messages.first?.serializedValue == "0:")
        #expect(try await database.commitLocalSyncMessagesAndEnqueue(messages) == 1)

        let stored = try categoryTemplateState("groceries", at: fixtureURL)
        #expect(stored.goalDef == nil)
        #expect(stored.settings == #"{"source":"ui"}"#)
        let month = try await database.fetchBudgetMonth(month: "2026-07")
        #expect(
            month.categoryGroups.first { $0.id == "group" }?
                .categories.first { $0.id == "groceries" }?
                .hasTemplateDefinition == false
        )
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
    }

    @Test func templateWriteFailsClosedWhenColumnsAreMissing() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()
        await #expect(throws: LocalFirstError.invalidLocalWrite(
            BudgetTemplateCategoryLock.Reason.missingColumns.testerFacingReason
        )) {
            _ = try await database.setCategoryTemplateMessages(
                categoryID: "groceries",
                goalDefJSON: #"[{"directive":"template","type":"simple","monthly":400,"priority":1}]"#,
                builder: &builder
            )
        }
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
    }

    @Test func templateWriteFailsClosedWhenGoalDefColumnExistsWithoutSettings() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()
        await #expect(throws: LocalFirstError.invalidLocalWrite(
            BudgetTemplateCategoryLock.Reason.missingColumns.testerFacingReason
        )) {
            _ = try await database.setCategoryTemplateMessages(
                categoryID: "groceries",
                goalDefJSON: nil,
                builder: &builder
            )
        }
    }

    @Test func templateWriteRefusesNoteManagedAndStaleCategories() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":500,"priority":0}]',
                template_settings = '{"source":"notes"}'
            WHERE id = 'groceries';
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', '#template 700');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()
        await #expect(throws: LocalFirstError.invalidLocalWrite(
            BudgetTemplateCategoryLock.Reason.staleNotes.testerFacingReason
        )) {
            _ = try await database.setCategoryTemplateMessages(
                categoryID: "groceries",
                goalDefJSON: nil,
                builder: &builder
            )
        }
        #expect(try categoryTemplateState("groceries", at: fixtureURL).goalDef?.contains("500") == true)
    }

    @Test func templateWriteRefusesMatchingNoteManagedCategory() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":500,"priority":0}]',
                template_settings = '{"source":"notes"}'
            WHERE id = 'groceries';
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', '#template 500');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()
        await #expect(throws: LocalFirstError.invalidLocalWrite(
            BudgetTemplateCategoryLock.Reason.noteManaged.testerFacingReason
        )) {
            _ = try await database.setCategoryTemplateMessages(
                categoryID: "groceries",
                goalDefJSON: nil,
                builder: &builder
            )
        }
        #expect(try categoryTemplateState("groceries", at: fixtureURL).goalDef?.contains("500") == true)
    }

    @Test func templateWriteRefusesUnsupportedTypesAndIncomingCutB() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"percentage","percent":10,"previous":false,"category":"all income","priority":0}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()
        await #expect(throws: LocalFirstError.invalidLocalWrite(
            BudgetTemplateCategoryLock.Reason.unsupportedType.testerFacingReason
        )) {
            _ = try await database.setCategoryTemplateMessages(
                categoryID: "groceries",
                goalDefJSON: #"[{"directive":"template","type":"simple","monthly":400,"priority":1}]"#,
                builder: &builder
            )
        }
    }

    @Test func templateWriteRefusesIncomingCutBOnEditableCategory() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories SET template_settings = '{"source":"ui"}' WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()
        await #expect(throws: LocalFirstError.invalidLocalWrite(
            BudgetTemplateCategoryLock.Reason.unsupportedType.testerFacingReason
        )) {
            _ = try await database.setCategoryTemplateMessages(
                categoryID: "groceries",
                goalDefJSON: #"[{"directive":"template","type":"percentage","percent":10,"previous":false,"category":"all income","priority":0}]"#,
                builder: &builder
            )
        }
        #expect(try categoryTemplateState("groceries", at: fixtureURL).goalDef == nil)
    }

    @Test func templateWriteRefusesUnknownEditorFieldsBeforeCreatingMessages() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories SET template_settings = '{"source":"ui"}' WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()
        await #expect(throws: LocalFirstError.invalidLocalWrite(
            BudgetTemplateCategoryLock.Reason.unsupportedType.testerFacingReason
        )) {
            _ = try await database.setCategoryTemplateMessages(
                categoryID: "groceries",
                goalDefJSON: #"[{"directive":"template","type":"simple","monthly":400,"priority":1,"futureField":true}]"#,
                builder: &builder
            )
        }
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
    }

    @Test func templateWritePreservesAutomationDescriptionWithoutChangingBudget() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories SET template_settings = '{"source":"ui"}' WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let before = try await database.fetchBudgetMonth(month: "2026-07")
        let json = try BudgetTemplateDefinition.encode([
            .monthlyFixed(
                amount: 400,
                now: Self.templateWriteNow,
                description: "Keep this note\nexactly"
            )
        ])
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.setCategoryTemplateMessages(
            categoryID: "groceries",
            goalDefJSON: json,
            builder: &builder
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        let after = try await database.fetchBudgetMonth(month: "2026-07")
        #expect(after.toBudget == before.toBudget)
        let snapshot = try await database.categoryTemplateEditorSnapshot(
            categoryID: "groceries",
            now: Self.templateWriteNow
        )
        #expect(snapshot.drafts.first?.description == "Keep this note\nexactly")
    }

    @Test func templateStoreSaveReloadsDefinitionAndDoesNotRecordHistory() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: """
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories SET template_settings = '{"source":"ui"}' WHERE id = 'groceries';
            """)
        let before = try await bundle.store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceriesBefore = try #require(
            before.month.categoryGroups.first { $0.id == "group" }?
                .categories.first { $0.id == "groceries" }
        )
        #expect(groceriesBefore.hasTemplateDefinition)

        let after = try await bundle.store.setCategoryTemplatesAndRefresh(
            categoryID: "groceries",
            drafts: [.monthlyFixed(amount: 250, now: Self.templateWriteNow)],
            budgetID: "group-1",
            month: "2026-07"
        )
        let groceriesAfter = try #require(
            after.month.categoryGroups.first { $0.id == "group" }?
                .categories.first { $0.id == "groceries" }
        )
        #expect(groceriesAfter.hasTemplateDefinition)
        #expect(after.month.toBudget == before.month.toBudget)
        #expect(try await bundle.store.recentBudgetActions(budgetID: "group-1").isEmpty)

        let cleared = try await bundle.store.setCategoryTemplatesAndRefresh(
            categoryID: "groceries",
            drafts: [],
            budgetID: "group-1",
            month: "2026-07"
        )
        #expect(
            cleared.month.categoryGroups.first { $0.id == "group" }?
                .categories.first { $0.id == "groceries" }?
                .hasTemplateDefinition == false
        )
        #expect(try await bundle.store.recentBudgetActions(budgetID: "group-1").isEmpty)
        #expect(cleared.month.toBudget == before.month.toBudget)
    }

    private static let templateWriteNow = Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 9, day: 15, hour: 12)
    )!

    private func categoryTemplateState(
        _ categoryID: String,
        at databaseURL: URL
    ) throws -> (goalDef: String?, settings: String?) {
        let queue = try DatabaseQueue(path: databaseURL.path)
        return try queue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT goal_def, template_settings FROM categories WHERE id = ?",
                arguments: [categoryID]
            ) else {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }
            return (row["goal_def"] as String?, row["template_settings"] as String?)
        }
    }

    private func zeroBudgetAmount(
        _ categoryID: String,
        at databaseURL: URL
    ) throws -> Int? {
        let queue = try DatabaseQueue(path: databaseURL.path)
        return try queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT amount
                    FROM zero_budgets
                    WHERE category = ? AND month = ?
                    LIMIT 1
                    """,
                arguments: [categoryID, 202607]
            )
        }
    }
}
