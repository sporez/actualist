import Foundation
import Testing
@testable import Actualist

@Suite("Budget template editor snapshot")
@MainActor
struct BudgetTemplateEditorSnapshotTests {
    private let fixtures = LocalFirstActualStoreTests()
    private let now = Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 9, day: 15, hour: 12)
    )!

    @Test func snapshotLoadsEditableUITemplatesAndSchedules() async throws {
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":400,"priority":1}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'groceries';
            CREATE TABLE schedules (
                id TEXT PRIMARY KEY,
                name TEXT,
                rule TEXT,
                completed INTEGER,
                tombstone INTEGER
            );
            INSERT INTO schedules VALUES ('rent', 'Rent', 'rent-rule', 0, 0);
            INSERT INTO schedules VALUES ('done', 'Old Rent', 'done-rule', 1, 0);
            INSERT INTO schedules VALUES ('ghost', 'Ghost', 'ghost-rule', 0, 1);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let snapshot = try await database.categoryTemplateEditorSnapshot(
            categoryID: "groceries",
            now: now
        )
        #expect(snapshot.categoryID == "groceries")
        #expect(snapshot.categoryName == "Groceries")
        #expect(snapshot.lock == .editable)
        #expect(snapshot.hasDefinition)
        #expect(snapshot.drafts == [.monthlyFixed(amount: 400, now: now)])
        #expect(snapshot.schedules == [BudgetTemplateScheduleOption(id: "rent", name: "Rent")])
    }

    @Test func snapshotNormalizesLegacyFixedCapToStandaloneLimit() async throws {
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"periodic","amount":125,"period":{"period":"week","amount":2},"starting":"2026-09-01","priority":1,"limit":{"amount":500,"hold":true,"period":"monthly"}}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let snapshot = try await database.categoryTemplateEditorSnapshot(
            categoryID: "groceries",
            now: now
        )
        #expect(snapshot.lock == .editable)
        #expect(snapshot.drafts == [
            .monthlyFixed(
                BudgetTemplateDraft.MonthlyFixed(
                    amount: 125,
                    priority: 1,
                    starting: "2026-09-01",
                    cadence: .week,
                    interval: 2
                )
            ),
            .balanceLimit(amount: 500, hold: true, period: .monthly)
        ])
    }

    @Test func snapshotLoadsStandaloneLimitAndRefillForRepair() async throws {
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"limit","amount":500,"period":"monthly","hold":false,"priority":null},{"directive":"template","type":"refill","priority":1}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let snapshot = try await database.categoryTemplateEditorSnapshot(
            categoryID: "groceries",
            now: now
        )
        #expect(snapshot.lock == .editable)
        #expect(snapshot.drafts == [
            .balanceLimit(amount: 500, period: .monthly),
            .refill(priority: 1)
        ])
    }

    @Test func snapshotLocksWhenColumnsAreMissing() async throws {
        let fixtureURL = try fixtures.makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let snapshot = try await database.categoryTemplateEditorSnapshot(
            categoryID: "groceries",
            now: now
        )
        #expect(snapshot.lock == .readOnly(.missingColumns))
        #expect(snapshot.drafts.isEmpty)
        #expect(!snapshot.hasDefinition)
    }

    @Test func snapshotUsesApplyIncomeCatalogOrderForPercentagePicker() async throws {
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 0);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def, template_settings)
                VALUES ('salary', 'Salary', 'income-group', 1, 0, 0, 1, NULL, NULL);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def, template_settings)
                VALUES ('bonus', 'Bonus', 'income-group', 1, 0, 0, 0, NULL, NULL);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let snapshot = try await database.categoryTemplateEditorSnapshot(
            categoryID: "groceries",
            now: now
        )
        #expect(snapshot.incomeCategories == [
            BudgetTemplateIncomeOption(id: "bonus", name: "Bonus"),
            BudgetTemplateIncomeOption(id: "salary", name: "Salary")
        ])
    }

    @Test func snapshotLocksNoteManagedAndKeepsCutADrafts() async throws {
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
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
        let snapshot = try await database.categoryTemplateEditorSnapshot(
            categoryID: "groceries",
            now: now
        )
        #expect(snapshot.lock == .readOnly(.noteManaged))
        #expect(snapshot.hasDefinition)
        #expect(snapshot.drafts == [.monthlyFixed(amount: 500, priority: 0, now: now)])
    }

    @Test func snapshotLocksUnsupportedTypesWithoutDrafts() async throws {
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"percentage","percent":10,"previous":false,"category":"all income","priority":0}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let snapshot = try await database.categoryTemplateEditorSnapshot(
            categoryID: "groceries",
            now: now
        )
        #expect(snapshot.lock == .readOnly(.unsupportedType))
        #expect(snapshot.drafts.isEmpty)
        #expect(snapshot.hasDefinition)
    }

    @Test func snapshotThrowsForMissingCategory() async throws {
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        await #expect(throws: LocalFirstError.invalidLocalWrite("missing category")) {
            _ = try await database.categoryTemplateEditorSnapshot(categoryID: "missing")
        }
    }
}
