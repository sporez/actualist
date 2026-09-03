import Foundation
import GRDB
import Testing
@testable import Actualist

@Suite("Empty category templates")
@MainActor
struct BudgetTemplateEmptyCategoryTests {
    @Test(arguments: ["NULL", "''", "'null'", "'[]'"], ["", "Ordinary category note"])
    func actualDefaultSourceAllowsCreationWithoutChangingNotesOrBudget(goalSQL: String, note: String) async throws {
        let fixtureURL = try LocalFirstActualStoreTests().makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings JSON DEFAULT '{"source": "notes"}';
            UPDATE categories SET goal_def = \(goalSQL) WHERE id = 'groceries';
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', '\(note)');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let before = try await database.fetchBudgetMonth(month: "2026-07")
        let snapshot = try await database.categoryTemplateEditorSnapshot(categoryID: "groceries")
        #expect(snapshot.drafts.isEmpty)
        #expect(!snapshot.hasDefinition)
        #expect(snapshot.lock == .editable)
        #expect(BudgetTemplateDoorKind.kind(hasDefinition: snapshot.hasDefinition, lock: snapshot.lock) == .add)
        #expect(!before.categoryGroups.flatMap(\.categories).contains { $0.hasTemplateDefinition })

        let browser = try await database.categoryTemplateBrowserSnapshot()
        let category = try #require(browser.categories.first { $0.id == "groceries" })
        #expect(category.lock == .editable)
        #expect(!category.hasDefinition)

        let json = #"[{"directive":"template","type":"simple","monthly":10,"priority":1}]"#
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.setCategoryTemplateMessages(
            categoryID: "groceries",
            goalDefJSON: json,
            builder: &builder
        )
        #expect(Set(messages.map(\.dataset)) == ["categories"])
        #expect(Set(messages.map(\.column)) == ["goal_def", "template_settings"])
        #expect(try await database.commitLocalSyncMessagesAndEnqueue(messages) == 2)
        #expect(try await database.pendingLocalSyncMessageCount() == 2)

        let saved = try await database.categoryTemplateEditorSnapshot(categoryID: "groceries")
        #expect(saved.lock == .editable)
        #expect(saved.hasDefinition)
        #expect(saved.drafts.count == 1)
        let after = try await database.fetchBudgetMonth(month: "2026-07")
        #expect(after.toBudget == before.toBudget)
        #expect(after.totalBudgeted == before.totalBudgeted)

        let queue = try DatabaseQueue(path: fixtureURL.path)
        let stored = try await queue.read { db in
            (
                note: try String.fetchOne(db, sql: "SELECT note FROM notes WHERE id = 'groceries'"),
                goal: try String.fetchOne(db, sql: "SELECT goal_def FROM categories WHERE id = 'groceries'"),
                settings: try String.fetchOne(db, sql: "SELECT template_settings FROM categories WHERE id = 'groceries'")
            )
        }
        #expect(stored.note == note)
        #expect(stored.goal == json)
        #expect(stored.settings == BudgetDatabase.uiTemplateSettingsJSON)
    }
}
