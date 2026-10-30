import Foundation
import GRDB
import Testing
@testable import Actualist

/// Month review with skipped and blocked categories: the preview prices the
/// same excluding command the reviewed apply runs, and skipped categories are
/// never written.
@Suite("Budget template exclusion preview")
@MainActor
struct BudgetTemplateExclusionPreviewTests {
    private let fixtures = LocalFirstActualStoreTests()

    /// Groceries is budgeted 500.00 with a 20.00 template, so Overwrite
    /// reduces it. Dining (30.00) and Rent (100.00) start empty. Income 10,000.00.
    private func makeDatabase(extraSQL: String = "") throws -> (BudgetDatabase, URL) {
        let url = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 2);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
            VALUES ('salary', 'Salary', 'income', 1, 0, 0, 1),
                   ('dining', 'Dining', 'group', 0, 0, 0, 2),
                   ('rent', 'Rent', 'group', 0, 0, 0, 3);
            INSERT INTO category_mapping VALUES ('salary', 'salary'), ('dining', 'dining'), ('rent', 'rent');
            INSERT INTO transactions VALUES ('income-txn', 'checking', 20260701, 1000000, 'salary', 0, NULL, 0);
            UPDATE categories SET template_settings = '{"source":"ui"}' WHERE id IN ('groceries', 'dining', 'rent');
            UPDATE categories SET goal_def = '[{"directive":"template","type":"simple","monthly":20,"priority":1}]'
            WHERE id = 'groceries';
            UPDATE categories SET goal_def = '[{"directive":"template","type":"simple","monthly":30,"priority":1}]'
            WHERE id = 'dining';
            UPDATE categories SET goal_def = '[{"directive":"template","type":"simple","monthly":100,"priority":1}]'
            WHERE id = 'rent';
            \(extraSQL)
            """)
        return (try BudgetDatabase(databaseURL: url, localNodeID: "node1"), url)
    }

    @Test func skippedTileIsRepricedOutAndApplyMatchesPreview() async throws {
        let (database, url) = try makeDatabase()
        let baseline = try ready(try await database.previewBudgetTemplatePair(month: "2026-07").overwrite)
        #expect(baseline.baselineTileIDs == ["groceries", "dining", "rent"])
        #expect(baseline.skipped.isEmpty)
        #expect(baseline.excludedCategoryIDs.isEmpty)

        let pair = try await database.previewBudgetTemplatePair(month: "2026-07", excluding: ["dining"])
        let selected = try ready(pair.overwrite)
        #expect(selected.excludedCategoryIDs == ["dining"])
        #expect(selected.baselineTileIDs == baseline.baselineTileIDs)
        #expect(selected.skipped.map(\.categoryID) == ["dining"])
        #expect(selected.skipped.first?.proposed == 3_000)
        #expect(selected.categories.map(\.categoryID).sorted() == ["groceries", "rent"])
        #expect(selected.assigned == baseline.assigned - 3_000)
        #expect(selected.reviewRevision == baseline.reviewRevision)

        var builder = LocalFirstSyncMessageBuilder()
        let applied = try await database.budgetTemplateApply(
            command: .overwrite.excluding(selected.excludedCategoryIDs),
            month: "2026-07",
            builder: &builder
        )
        #expect(Set(applied.assignments.map(\.categoryID)) == ["groceries", "rent"])
        #expect(!applied.messages.contains { $0.row.contains("dining") })
        let proposed = Dictionary(uniqueKeysWithValues: selected.categories.map { ($0.categoryID, $0.proposed) })
        for assignment in applied.assignments {
            #expect(proposed[assignment.categoryID] == assignment.amount)
        }
        _ = try await database.commitLocalSyncMessagesAndEnqueue(applied.messages)
        #expect(try zeroBudgetAmount("dining", at: url) == 0)
        #expect(try zeroBudgetAmount("groceries", at: url) == 2_000)
        #expect(try zeroBudgetAmount("rent", at: url) == 10_000)
    }

    @Test func skipCountsOnlyForTilesTheModeShows() async throws {
        let (database, _) = try makeDatabase()
        let pair = try await database.previewBudgetTemplatePair(month: "2026-07", excluding: ["groceries"])
        // Fill Empty never shows budgeted Groceries, so the carried skip is ignored there.
        let fill = try ready(pair.fillEmpty)
        #expect(fill.excludedCategoryIDs.isEmpty)
        #expect(fill.skipped.isEmpty)
        #expect(fill.categories.map(\.categoryID).sorted() == ["dining", "rent"])

        let overwrite = try ready(pair.overwrite)
        #expect(overwrite.excludedCategoryIDs == ["groceries"])
        // Its 500.00 stays spent: nothing is released.
        #expect(overwrite.released == 0)
        let baseline = try ready(try await database.previewBudgetTemplatePair(month: "2026-07").overwrite)
        #expect(baseline.released == 48_000)
        #expect(overwrite.availableBefore == baseline.availableBefore)
    }

    @Test func excludingEveryTileWritesNothingInsteadOfTheWholeMonth() async throws {
        let (database, url) = try makeDatabase()
        let all: Set<String> = ["groceries", "dining", "rent"]
        let selected = try ready(try await database.previewBudgetTemplatePair(month: "2026-07", excluding: all).overwrite)
        #expect(selected.categories.isEmpty)
        #expect(selected.skipped.count == 3)

        var builder = LocalFirstSyncMessageBuilder()
        let applied = try await database.budgetTemplateApply(
            command: .overwrite.excluding(all),
            month: "2026-07",
            builder: &builder
        )
        #expect(applied.assignments.isEmpty)
        #expect(applied.messages.isEmpty)
        #expect(try zeroBudgetAmount("groceries", at: url) == 50_000)
    }

    @Test func unsupportedTemplateIsBlockedAndTheRestCanApply() async throws {
        let (database, url) = try makeDatabase(extraSQL: """
            UPDATE categories SET goal_def = 'not-json' WHERE id = 'rent';
            """)
        let pair = try await database.previewBudgetTemplatePair(month: "2026-07")
        for outcome in [pair.fillEmpty, pair.overwrite] {
            let preview = try ready(outcome)
            #expect(preview.blocked == [.init(categoryID: "rent", name: "Rent", reason: .unsupported)])
            #expect(preview.excludedCategoryIDs == ["rent"])
            #expect(!preview.categories.contains { $0.categoryID == "rent" })
        }

        await #expect(throws: LocalFirstError.self) {
            var unscoped = LocalFirstSyncMessageBuilder()
            _ = try await database.budgetTemplateApply(command: .overwrite, month: "2026-07", builder: &unscoped)
        }
        var builder = LocalFirstSyncMessageBuilder()
        let overwrite = try ready(pair.overwrite)
        let applied = try await database.budgetTemplateApply(
            command: .overwrite.excluding(overwrite.excludedCategoryIDs),
            month: "2026-07",
            builder: &builder
        )
        #expect(Set(applied.assignments.map(\.categoryID)) == ["groceries", "dining"])
        _ = try await database.commitLocalSyncMessagesAndEnqueue(applied.messages)
        #expect(try zeroBudgetAmount("rent", at: url) == 0)
    }

    @Test func staleNoteTemplateIsBlockedInsteadOfFailingTheReview() async throws {
        let (database, _) = try makeDatabase(extraSQL: """
            UPDATE categories SET template_settings = '{"source":"notes"}' WHERE id = 'dining';
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('dining', '#template 45');
            """)
        let preview = try ready(try await database.previewBudgetTemplatePair(month: "2026-07").fillEmpty)
        #expect(preview.blocked.map(\.categoryID) == ["dining"])
        #expect(preview.blocked.first?.reason == .staleNote)
        #expect(preview.categories.map(\.categoryID) == ["rent"])
        // A skip on top of a blocked category keeps both out of the run.
        let both = try ready(try await database.previewBudgetTemplatePair(month: "2026-07", excluding: ["rent"]).fillEmpty)
        #expect(both.excludedCategoryIDs == ["dining", "rent"])
        #expect(both.categories.isEmpty)
    }

    private func ready(_ outcome: BudgetTemplatePreviewOutcome) throws -> BudgetTemplateApplyPreview {
        guard case .ready(let preview) = outcome else {
            Issue.record("Expected a ready preview, got \(outcome)")
            throw CancellationError()
        }
        return preview
    }

    private func zeroBudgetAmount(_ categoryID: String, at databaseURL: URL) throws -> Int {
        let queue = try DatabaseQueue(path: databaseURL.path)
        return try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT amount FROM zero_budgets WHERE category = ? AND month = ? LIMIT 1",
                arguments: [categoryID, 202607]
            ) ?? 0
        }
    }
}
