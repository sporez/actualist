import Foundation
import GRDB
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    // MARK: - Pure parser

    @Test func noteParserClassifiesSimpleAndGoalDirectives() {
        let directives = BudgetTemplateNoteParser.directives(in: "#template 500\n#goal 750")
        #expect(directives.count == 2)
        #expect(directives[0].keyword == "template")
        #expect(directives[0].type == "simple")
        #expect(directives[0].monthly == 500)
        #expect(directives[1].keyword == "goal")
        #expect(directives[1].type == "goal")
        #expect(directives[1].amount == 750)
    }

    @Test func noteParserClassifiesKeywordTypes() {
        let note = """
        #template remainder
        #template copy
        #template average 3
        #template schedule Rent
        #template spend 300 from 2026-07 to 2026-09
        #template by 2026-12 200
        #template up to 1000
        #template 10% of income
        #template 500 monthly
        """
        let directives = BudgetTemplateNoteParser.directives(in: note)
        let types = directives.map(\.type)
        #expect(types == [
            "remainder", "copy", "average", "schedule",
            "spend", "by", "limit", "percentage", "periodic"
        ])
    }

    @Test func noteParserMarksMalformedDirectiveAsUntypeable() {
        let directives = BudgetTemplateNoteParser.directives(in: "#template bad")
        #expect(directives.count == 1)
        #expect(directives[0].type == nil)
    }

    @Test func noteParserIgnoresOrdinaryNoteText() {
        let directives = BudgetTemplateNoteParser.directives(
            in: "Remember to budget conservatively.\n# not a directive\n#template 500"
        )
        #expect(directives.count == 1)
        #expect(directives[0].type == "simple")
    }

    @Test func templateAppliesWhenNoteMatchesGoalDef() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":700,"priority":0}]'
            WHERE id = 'groceries';
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', '#template 700');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try zeroBudgetAmount(at: fixtureURL, category: "groceries") == 70_000)
    }

    @Test func templateRefusesWhenNoteValueChangedSinceGoalDefGenerated() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":500,"priority":0}]'
            WHERE id = 'groceries';
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', '#template 700');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        await #expect(throws: LocalFirstError.self) {
            _ = try await database.budgetTemplateMessages(
                command: .category("groceries"),
                month: "2026-07",
                builder: &builder
            )
        }
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        // The stale 500 definition was not applied.
        #expect(try zeroBudgetAmount(at: fixtureURL, category: "groceries") == 50_000)
    }

    @Test func templateRefusesWhenNoteTemplateTypeChanged() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":500,"priority":0}]'
            WHERE id = 'groceries';
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', '#template remainder');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        do {
            _ = try await database.budgetTemplateMessages(
                command: .category("groceries"),
                month: "2026-07",
                builder: &builder
            )
            Issue.record("Expected a type-change to be refused")
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            #expect(reason.contains("stale"))
        }
        #expect(try zeroBudgetAmount(at: fixtureURL, category: "groceries") == 50_000)
    }

    @Test func templateRefusesWhenNoteManagedDirectiveRemoved() async throws {
        // Explicit note-managed source: the directive was removed from the note
        // but Actual has not cleared goal_def yet.
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":500,"priority":0}]',
                template_settings = '{"source":"notes"}'
            WHERE id = 'groceries';
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', 'Just a plain note now.');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        do {
            _ = try await database.budgetTemplateMessages(
                command: .category("groceries"),
                month: "2026-07",
                builder: &builder
            )
            Issue.record("Expected a removed directive to be refused")
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            #expect(reason.contains("no longer contains"))
        }
        #expect(try zeroBudgetAmount(at: fixtureURL, category: "groceries") == 50_000)
    }

    @Test func templateSkipsCategoryWhenNoteManagedGoalAlreadyCleared() async throws {
        // goal_def is already empty (Actual cleared it after the #goal was
        // removed). Nothing to apply, no refusal.
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE zero_budgets ADD COLUMN goal INTEGER;
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', 'No goal anymore.');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        )
        #expect(messages.isEmpty)
        #expect(try zeroBudgetAmount(at: fixtureURL, category: "groceries") == 50_000)
    }

    @Test func templateAppliesUIManagedDefinitionWithOrdinaryNote() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":700,"priority":0}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'groceries';
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', 'Ordinary note with no directive.');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try zeroBudgetAmount(at: fixtureURL, category: "groceries") == 70_000)
    }

    @Test func templateTransitionFromNoteToUISourcePreservesDefinition() async throws {
        // Was note-managed, now UI-managed with an ordinary note: preserve and
        // apply the UI-authored definition.
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":700,"priority":0}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'groceries';
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', 'Switched to the UI editor.');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try zeroBudgetAmount(at: fixtureURL, category: "groceries") == 70_000)
    }

    @Test func templateTransitionFromUIToNoteSourceValidatesAgainstNote() async throws {
        // Was UI-managed, now note-managed (`#template 700`). The UI goal_def
        // (700) matches the note → applies. A mismatched UI goal_def would
        // refuse (covered conceptually by the value-change test).
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":700,"priority":0}]',
                template_settings = '{"source":"notes"}'
            WHERE id = 'groceries';
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', '#template 700');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try zeroBudgetAmount(at: fixtureURL, category: "groceries") == 70_000)
    }

    @Test func templateRefusesMalformedNoteAndDoesNotUseStaleValidDefinition() async throws {
        // Note became malformed; goal_def still holds the previous valid
        // definition. Must refuse rather than apply the stale valid def.
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":500,"priority":0}]'
            WHERE id = 'groceries';
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', '#template bad');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        do {
            _ = try await database.budgetTemplateMessages(
                command: .category("groceries"),
                month: "2026-07",
                builder: &builder
            )
            Issue.record("Expected a malformed note to be refused")
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            #expect(reason.contains("malformed"))
        }
        #expect(try zeroBudgetAmount(at: fixtureURL, category: "groceries") == 50_000)
    }

    @Test func templateAppliesConsistentlyWhenNoteAndGoalDefAreBothMalformed() async throws {
        // Note is malformed and goal_def holds the matching error entry: fail
        // consistently (no assignment), do not throw a staleness error.
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"error","type":"error","line":"#template bad","error":"parse failure"}]'
            WHERE id = 'groceries';
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', '#template bad');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        )
        #expect(messages.isEmpty)
        #expect(try zeroBudgetAmount(at: fixtureURL, category: "groceries") == 50_000)
    }

    @Test func templateStillAppliesWhenNoNotesTableExists() async throws {
        // Regression guard: budgets without a `notes` table (fixtures, older
        // budgets) keep applying goal_def directly.
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":700,"priority":0}]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try zeroBudgetAmount(at: fixtureURL, category: "groceries") == 70_000)
    }

    @Test func templateStalenessRefusalIsScopedToAppliedCategories() async throws {
        // A stale note-managed category that is NOT in the targeted apply scope
        // must not block applying a different, fresh category.
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":500,"priority":0}]'
            WHERE id = 'groceries';
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
            VALUES ('utilities-stale', 'Utilities', 'group', 0, 0, 0, 2,
                '[{"directive":"template","type":"simple","monthly":500,"priority":0}]');
            INSERT INTO category_mapping VALUES ('utilities-stale', 'utilities-stale');
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('utilities-stale', '#template 700');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        // Target only groceries; the stale utilities-stale category is out of
        // scope and must not cause a refusal.
        let messages = try await database.budgetTemplateMessages(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try zeroBudgetAmount(at: fixtureURL, category: "groceries") == 50_000)
    }

    // MARK: - Per-type staleness regression

    /// Runs an apply for `groceries` and returns `true` only when the staleness
    /// guard fired (the category was refused because its note-managed goal_def
    /// is stale relative to the note).
    private func applyStalenessFired(goalDef: String, note: String, extraSQL: String = "") async throws -> Bool {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories
            SET goal_def = '\(goalDef)',
                template_settings = '{"source":"notes"}'
            WHERE id = 'groceries';
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', '\(note)');
            \(extraSQL)
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        do {
            _ = try await database.budgetTemplateMessages(
                command: .category("groceries"),
                month: "2026-07",
                builder: &builder
            )
            return false
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            return reason.contains("stale")
        }
    }

    @Test func scheduleTemplateRefusesStaleNoteAndAllowsMatching() async throws {
        let def = #"[{"directive":"template","type":"schedule","name":"Rent","priority":0}]"#
        #expect(try await applyStalenessFired(goalDef: def, note: "#template schedule Groceries") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "No directive anymore.") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template schedule Rent") == false)
    }

    @Test func percentageTemplateRefusesStaleNoteAndAllowsMatching() async throws {
        let def = #"[{"directive":"template","type":"percentage","percent":10,"previous":false,"category":"all income","priority":0}]"#
        #expect(try await applyStalenessFired(goalDef: def, note: "#template 25% of income") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template 10% of Food") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "plain note") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template 10% of income") == false)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template 10% of all income") == false)
    }

    @Test func spendTemplateRefusesStaleNoteAndAllowsMatching() async throws {
        let def = #"[{"directive":"template","type":"spend","amount":300,"month":"2026-09","from":"2026-07","priority":0}]"#
        #expect(try await applyStalenessFired(goalDef: def, note: "#template spend 999 from 2026-07 to 2026-09") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template spend 300 from 2026-08 to 2026-10") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "removed") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template spend 300 from 2026-07 to 2026-09") == false)
    }

    @Test func byTemplateRefusesStaleNoteAndAllowsMatching() async throws {
        let def = #"[{"directive":"template","type":"by","amount":200,"month":"2026-12","priority":0}]"#
        #expect(try await applyStalenessFired(goalDef: def, note: "#template by 2026-12 999") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template by 2026-11 200") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "removed") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template by 2026-12 200") == false)
    }

    @Test func periodicTemplateRefusesStaleNoteAndAllowsMatching() async throws {
        let def = #"[{"directive":"template","type":"periodic","amount":500,"period":{"amount":1,"period":"month"},"priority":0}]"#
        #expect(try await applyStalenessFired(goalDef: def, note: "#template 700 monthly") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template 500 weekly") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "removed") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template 500 monthly") == false)
    }

    @Test func copyTemplateRefusesStaleNoteAndAllowsMatching() async throws {
        let def = #"[{"directive":"template","type":"copy","lookBack":1,"priority":0}]"#
        #expect(try await applyStalenessFired(goalDef: def, note: "#template copy 3") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "removed") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template copy") == false)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template copy 1") == false)
    }

    @Test func averageTemplateRefusesStaleNoteAndAllowsMatching() async throws {
        let def = #"[{"directive":"template","type":"average","numMonths":3,"priority":0}]"#
        #expect(try await applyStalenessFired(goalDef: def, note: "#template average 6") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "removed") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template average 3") == false)
    }

    @Test func remainderTemplateRefusesStaleNoteAndAllowsMatching() async throws {
        let def = #"[{"directive":"template","type":"remainder","weight":1,"priority":null}]"#
        #expect(try await applyStalenessFired(goalDef: def, note: "#template 500") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "removed") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template remainder") == false)
    }

    @Test func limitTemplateRefusesStaleNoteAndAllowsMatching() async throws {
        let def = #"[{"directive":"template","type":"limit","amount":1000,"period":"monthly","priority":null}]"#
        #expect(try await applyStalenessFired(goalDef: def, note: "#template up to 2500") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template up to 1000 daily") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "removed") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template up to 1000") == false)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template up to 1000 monthly") == false)
    }

    @Test func simpleTemplateWithAttachedLimitRefusesStaleNote() async throws {
        let def = #"[{"directive":"template","type":"simple","monthly":500,"limit":{"amount":1000,"period":"monthly"},"priority":0}]"#
        #expect(try await applyStalenessFired(goalDef: def, note: "#template 500 up to 2000") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template 700 up to 1000") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "#template 500 up to 1000") == false)
    }

    @Test func goalTemplateRefusesStaleAmountNote() async throws {
        let def = #"[{"directive":"goal","type":"goal","amount":500,"priority":null}]"#
        #expect(try await applyStalenessFired(goalDef: def, note: "#goal 750") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "removed") == true)
        #expect(try await applyStalenessFired(goalDef: def, note: "#goal 500") == false)
    }

    // MARK: - Helpers

    private func zeroBudgetAmount(at databaseURL: URL, category: String, month: Int = 202607) throws -> Int? {
        let queue = try DatabaseQueue(path: databaseURL.path)
        return try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT amount FROM zero_budgets WHERE category = ? AND month = ?",
                arguments: [category, month]
            )
        }
    }
}
