import Foundation
import Testing
@testable import Actualist

@Suite("Budget template browser snapshot")
@MainActor
struct BudgetTemplateBrowserSnapshotTests {
    private let fixtures = LocalFirstActualStoreTests()
    private let now = Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 9, day: 15, hour: 12)
    )!

    @Test func indexListsTemplatedCategoriesAndPickerOmitsThem() async throws {
        let database = try BudgetDatabase(
            databaseURL: try makeBrowserFixture(),
            localNodeID: "node1"
        )
        let snapshot = try await database.categoryTemplateBrowserSnapshot(now: now)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0) })

        #expect(snapshot.month == "2026-09")
        #expect(snapshot.categories.map(\.id) == [
            "salary", "groceries", "hidden-cat", "spare",
            "rent", "utilities", "archived", "spare-hidden",
        ])
        #expect(byID["dead"] == nil)

        #expect(byID["groceries"]?.hasDefinition == true)
        #expect(byID["groceries"]?.lock == .editable)
        #expect(byID["groceries"]?.drafts == [.monthlyFixed(amount: 400, now: now)])
        #expect(byID["groceries"]?.isEffectivelyHidden == false)

        #expect(byID["spare"]?.hasDefinition == false)
        #expect(byID["utilities"]?.hasDefinition == false)
        #expect(byID["spare-hidden"]?.hasDefinition == false)

        #expect(byID["hidden-cat"]?.isEffectivelyHidden == true)
        #expect(byID["archived"]?.isEffectivelyHidden == true)
        #expect(byID["archived"]?.groupName == "Archive")
        #expect(byID["salary"]?.isIncome == true)
        #expect(byID["salary"]?.hasDefinition == true)
    }

    @Test func missingColumnsLockEveryCategory() async throws {
        let fixtureURL = try fixtures.makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let snapshot = try await database.categoryTemplateBrowserSnapshot(now: now)
        #expect(snapshot.categories.map(\.id) == ["groceries"])
        #expect(snapshot.categories.first?.hasDefinition == false)
        #expect(snapshot.categories.first?.lock == .readOnly(.missingColumns))
    }

    @Test func noteManagedAndUnsupportedStayInTheIndex() async throws {
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
                VALUES ('percent', 'Percent', 'group', 0, 0, 0, 2);
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":500,"priority":0}]',
                template_settings = '{"source":"note"}'
            WHERE id = 'groceries';
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"percentage","percent":10,"previous":false,"category":"all income","priority":0}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'percent';
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', '#template 500');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let snapshot = try await database.categoryTemplateBrowserSnapshot(now: now)
        let groceries = try #require(snapshot.categories.first { $0.id == "groceries" })
        let percent = try #require(snapshot.categories.first { $0.id == "percent" })
        #expect(groceries.hasDefinition)
        #expect(groceries.lock == .readOnly(.noteManaged))
        #expect(groceries.drafts == [.monthlyFixed(amount: 500, priority: 0, now: now)])
        #expect(percent.hasDefinition)
        #expect(percent.lock == .readOnly(.unsupportedType))
        #expect(percent.drafts.isEmpty)
    }

    @Test func storeSnapshotRefreshesAfterClearingATemplate() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(additionalFixtureSQL: """
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories SET template_settings = '{"source":"ui"}';
            """)
        let before = try await bundle.store.categoryTemplateBrowserSnapshot(budgetID: "group-1")
        #expect(before.categories.contains { $0.id == "groceries" && $0.hasDefinition })

        _ = try await bundle.store.setCategoryTemplatesAndRefresh(
            categoryID: "groceries",
            drafts: [],
            budgetID: "group-1",
            month: "2026-07"
        )
        let after = try await bundle.store.categoryTemplateBrowserSnapshot(budgetID: "group-1")
        #expect(after.categories.contains { $0.id == "groceries" && $0.hasDefinition } == false)
        #expect(after.month == "2026-07")
    }

    private func makeBrowserFixture() throws -> URL {
        try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 0);
            INSERT INTO category_groups VALUES ('bills', 'Bills', 0, 0, 0, 2);
            INSERT INTO category_groups VALUES ('archive', 'Archive', 0, 1, 0, 3);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
                VALUES ('salary', 'Salary', 'income', 1, 0, 0, 1);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
                VALUES ('rent', 'Rent', 'bills', 0, 0, 0, 1);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
                VALUES ('utilities', 'Utilities', 'bills', 0, 0, 0, 2);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
                VALUES ('hidden-cat', 'Old Stuff', 'group', 0, 1, 0, 2);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
                VALUES ('archived', 'Archived', 'archive', 0, 0, 0, 1);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
                VALUES ('spare', 'Spare', 'group', 0, 0, 0, 3);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
                VALUES ('spare-hidden', 'Spare Hidden', 'archive', 0, 0, 0, 2);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
                VALUES ('dead', 'Dead', 'group', 0, 0, 1, 9);
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":400,"priority":1}]',
                template_settings = '{"source":"ui"}'
            WHERE id IN ('groceries', 'rent', 'salary', 'hidden-cat', 'archived', 'dead');
            UPDATE categories
            SET template_settings = '{"source":"ui"}'
            WHERE id IN ('utilities', 'spare', 'spare-hidden');
            """)
    }
}
