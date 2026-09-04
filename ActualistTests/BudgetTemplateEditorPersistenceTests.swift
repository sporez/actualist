import Foundation
import GRDB
import Testing
@testable import Actualist

@Suite("Template editor persistence acceptance")
@MainActor
struct BudgetTemplateEditorPersistenceTests {
    private let now = BudgetTemplateCalendar.validatedDate("2026-07-15")!
    private let zeroCap = #"[{"directive":"template","type":"simple","monthly":0,"priority":1,"limit":{"amount":100,"hold":false,"period":"monthly"},"description":"Cap note"},{"directive":"template","type":"periodic","amount":400,"period":{"period":"month","amount":1},"starting":"2026-07-01","priority":1}]"#

    @Test func legacyZeroCapSurvivesSaveWithIdenticalDemandAndOutboxOnlyDefinitionChanges() async throws {
        let url = try makeFixture()
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE categories SET goal_def = ? WHERE id = 'groceries'", arguments: [zeroCap])
        }
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "template-acceptance")
        let before = try await database.dryRunCategoryTemplate(categoryID: "groceries", goalDefJSON: zeroCap, month: "2026-07", currentMonth: "2026-07")
        let snapshot = try await database.categoryTemplateEditorSnapshot(categoryID: "groceries", now: now)
        #expect(snapshot.drafts.count == 2)
        #expect(snapshot.drafts.first?.description == "Cap note")
        let json = try BudgetTemplateDefinition.encode(snapshot.drafts)
        let after = try await database.dryRunCategoryTemplate(categoryID: "groceries", goalDefJSON: json, month: "2026-07", currentMonth: "2026-07")
        #expect(before.budgeted == after.budgeted)
        #expect(after.budgeted == 10_000)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.setCategoryTemplateMessages(categoryID: "groceries", goalDefJSON: json, builder: &builder)
        #expect(messages.map(\.column) == ["goal_def"])
        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        #expect(try await database.pendingLocalSyncMessageCount() == 1)
        let reopened = try await database.categoryTemplateEditorSnapshot(categoryID: "groceries", now: now)
        #expect(reopened.drafts == snapshot.drafts)
        #expect(try budgetAmount(url: url) == 50_000)
        let preserved = try await queue.read { db in try String.fetchOne(db, sql: "SELECT note FROM notes WHERE id = 'groceries'") }
        #expect(preserved == "Category note\n#cleanup same")
    }

    @Test func limitAndRefillSaveWithoutAnotherContributor() async throws {
        let url = try makeFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "template-acceptance")
        let drafts: [BudgetTemplateDraft] = [.balanceLimit(amount: 500), .refill(description: "Fill the gap")]
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.setCategoryTemplateMessages(categoryID: "groceries", goalDefJSON: BudgetTemplateDefinition.encode(drafts), builder: &builder)
        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        #expect(try await database.categoryTemplateEditorSnapshot(categoryID: "groceries", now: now).drafts == drafts)
        #expect(try budgetAmount(url: url) == 50_000)
    }

    @Test func repairableInvalidCommandsProduceNoMessagesAndValidCorrectionSaves() async throws {
        let url = try makeFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "template-acceptance")
        let malformed = #"[{"directive":"template","type":"periodic","amount":100,"period":{"period":"month","amount":1},"starting":"2026-02-30","priority":1}]"#
        try await DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: "UPDATE categories SET goal_def = ? WHERE id = 'groceries'", arguments: [malformed])
        }
        let snapshot = try await database.categoryTemplateEditorSnapshot(categoryID: "groceries", now: now)
        #expect(snapshot.lock == .editable)
        var builder = LocalFirstSyncMessageBuilder()
        await #expect(throws: (any Error).self) {
            _ = try await database.setCategoryTemplateMessages(categoryID: "groceries", goalDefJSON: malformed, builder: &builder)
        }
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        let corrected = try BudgetTemplateDefinition.encode([.monthlyFixed(amount: 100, now: now)])
        let messages = try await database.setCategoryTemplateMessages(categoryID: "groceries", goalDefJSON: corrected, builder: &builder)
        #expect(messages.count == 1)
    }

    @Test(arguments: ["USD", "JPY", "", "USD-hide"], [false, true])
    func bothPreviewModesAgreeWithPersistedApplyAcrossCurrencies(code: String, tracking: Bool) async throws {
        for command in [BudgetTemplateCommand.fillEmpty, .overwrite, .category("groceries")] {
            try await verifyPreview(code: code, tracking: tracking, command: command)
        }
    }

    private func verifyPreview(code: String, tracking: Bool, command: BudgetTemplateCommand) async throws {
        let url = try makeFixture()
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: "ALTER TABLE zero_budgets ADD COLUMN id TEXT")
            try db.execute(sql: "UPDATE zero_budgets SET id = '202607-groceries'")
            try db.execute(sql: "ALTER TABLE zero_budgets ADD COLUMN goal INTEGER")
            try db.execute(sql: "ALTER TABLE zero_budgets ADD COLUMN long_goal INTEGER")
            try db.execute(sql: "INSERT INTO transactions (id, acct, date, amount, category, tombstone) VALUES ('income', 'checking', 20260701, 20000, NULL, 0)")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS preferences (id TEXT PRIMARY KEY, value TEXT)")
            try db.execute(sql: "INSERT OR REPLACE INTO preferences VALUES ('defaultCurrencyCode', ?)", arguments: [code == "USD-hide" ? "USD" : code])
            try db.execute(sql: "INSERT OR REPLACE INTO preferences VALUES ('hideFraction', ?)", arguments: [code == "USD-hide" ? "true" : "false"])
            if tracking {
                try db.execute(sql: "CREATE TABLE reflect_budgets AS SELECT * FROM zero_budgets")
                try db.execute(sql: "INSERT OR REPLACE INTO preferences VALUES ('budgetType', 'tracking')")
            }
            let json = try BudgetTemplateDefinition.encode([.monthlyFixed(amount: 123.45, now: now), .balanceLimit(amount: 200), .goal(amount: 1000)])
            try db.execute(sql: "UPDATE categories SET goal_def = ? WHERE id = 'groceries'", arguments: [json])
        }
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "template-acceptance")
        let preview = try await database.previewBudgetTemplate(command: command, month: "2026-07", currentMonth: "2026-07", now: now)
        #expect(preview.isTrackingBudget == tracking)
        #expect(preview.currency.decimalPlaces == (code == "JPY" ? 0 : 2))
        var builder = LocalFirstSyncMessageBuilder()
        let applied = try await database.budgetTemplateApply(command: command, month: "2026-07", currentMonth: "2026-07", builder: &builder)
        #expect(preview.categories.map(\.proposed) == applied.assignments.map(\.amount))
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        _ = try await database.applyLocalSyncMessages(applied.messages)
        for category in preview.categories {
            let actual = try await queue.read { db in
                try Int.fetchOne(db, sql: "SELECT amount FROM \(tracking ? "reflect_budgets" : "zero_budgets") WHERE category = ? AND month = 202607", arguments: [category.categoryID])
            }
            #expect(actual == category.proposed)
        }
    }

    private func makeFixture() throws -> URL {
        try LocalFirstActualStoreTests().makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories SET template_settings = '{"source":"ui"}' WHERE id = 'groceries';
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', 'Category note
            #cleanup same');
            """)
    }

    private func budgetAmount(url: URL) throws -> Int? {
        try DatabaseQueue(path: url.path).read { db in
            try Int.fetchOne(db, sql: "SELECT amount FROM zero_budgets WHERE category = 'groceries' AND month = 202607")
        }
    }
}
