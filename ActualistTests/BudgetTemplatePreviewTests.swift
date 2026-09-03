import Foundation
import GRDB
import Testing
@testable import Actualist

@Suite("Budget template preview")
@MainActor
struct BudgetTemplatePreviewTests {
    private let engine = BudgetTemplateEngine()

    @Test func computeWritesStillClampsPriorityDemand() throws {
        let entries = try #require(try engine.decodeSupportedEntries(json: """
            [
              {"directive":"template","type":"simple","monthly":18,"priority":150},
              {"directive":"template","type":"simple","monthly":32,"priority":150}
            ]
            """))
        let writes = try engine.computeWrites(
            categories: [
                "cat": .init(entries: entries, fromLastMonth: 0, copiedBudgetedByLookBack: [:])
            ],
            orderedCategoryIDs: ["cat"],
            monthValue: 202607,
            availableBudget: 500
        )
        #expect(writes.map(\.amount) == [500])
    }

    @Test func categoryDryRunReportsUnclampedDemandAndContributions() throws {
        let entries = try #require(try engine.decodeSupportedEntries(json: """
            [
              {"directive":"template","type":"simple","monthly":18,"priority":150},
              {"directive":"template","type":"simple","monthly":32,"priority":150}
            ]
            """))
        let plan = try engine.computePlan(
            categories: [
                "cat": .init(entries: entries, fromLastMonth: 0, copiedBudgetedByLookBack: [:])
            ],
            orderedCategoryIDs: ["cat"],
            monthValue: 202607,
            availableBudget: 500,
            skipAvailableClamp: true
        )
        #expect(plan.writes.map(\.amount) == [5_000])
        #expect(plan.contributions["cat"] == [1_800, 3_200])
        #expect(plan.contributions["cat"]?.reduce(0, +) == plan.writes[0].amount)
    }

    @Test func remainderContributionsFollowWeightAndSumToAllocation() throws {
        let entries = try #require(try engine.decodeSupportedEntries(json: """
            [
              {"directive":"template","type":"simple","monthly":10,"priority":0},
              {"directive":"template","type":"remainder","weight":1,"priority":null},
              {"directive":"template","type":"remainder","weight":3,"priority":null}
            ]
            """))
        let plan = try engine.computePlan(
            categories: [
                "cat": .init(entries: entries, fromLastMonth: 0, copiedBudgetedByLookBack: [:])
            ],
            orderedCategoryIDs: ["cat"],
            monthValue: 202607,
            availableBudget: 5_000,
            skipAvailableClamp: false
        )
        #expect(plan.writes.map(\.amount) == [5_000])
        let shares = try #require(plan.contributions["cat"])
        #expect(shares[0] == 1_000)
        #expect(shares[1] + shares[2] == 4_000)
        #expect(shares[2] == 3_000)
        #expect(shares.reduce(0, +) == 5_000)
    }

    @Test func applyPreviewMatchesWritePathAndDoesNotMutateBudget() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":20,"priority":1}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let before = try zeroBudgetAmount("groceries", at: fixtureURL)
        let preview = try await database.previewBudgetTemplate(
            command: .category("groceries"),
            month: "2026-07"
        )
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == before)

        var builder = LocalFirstSyncMessageBuilder()
        let applied = try await database.budgetTemplateApply(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        )
        #expect(preview.categories.map(\.proposed) == applied.assignments.map(\.amount))
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == before)
        _ = try await database.applyLocalSyncMessages(applied.messages)
        if let proposed = preview.categories.first(where: { $0.categoryID == "groceries" })?.proposed {
            #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == proposed)
        }
    }

    @Test func categoryDryRunUsesDraftsAndLeavesBudgetUnchanged() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let now = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 7, day: 15, hour: 12)
        )!
        let json = try BudgetTemplateDefinition.encode([
            .monthlyFixed(amount: 400, now: now)
        ])
        let before = try zeroBudgetAmount("groceries", at: fixtureURL)
        let dryRun = try await database.dryRunCategoryTemplate(
            categoryID: "groceries",
            goalDefJSON: json,
            month: "2026-07"
        )
        #expect(dryRun.budgeted == 40_000)
        #expect(dryRun.perTemplate == [40_000])
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == before)
    }

    @Test func missingCategoryDryRunIsZeros() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let fixtureURL = try fixtures.makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let json = try BudgetTemplateDefinition.encode([.monthlyFixed(amount: 50)])
        let dryRun = try await database.dryRunCategoryTemplate(
            categoryID: "missing",
            goalDefJSON: json,
            month: "2026-07"
        )
        #expect(dryRun.budgeted == 0)
        #expect(dryRun.perTemplate == [0])
    }

    @Test func fillAndOverwritePreviewsMatchApplyAssignments() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":20,"priority":1}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let fillPreview = try await database.previewBudgetTemplate(
            command: .fillEmpty,
            month: "2026-07"
        )
        var fillBuilder = LocalFirstSyncMessageBuilder()
        let fillApplied = try await database.budgetTemplateApply(
            command: .fillEmpty,
            month: "2026-07",
            builder: &fillBuilder
        )
        #expect(fillPreview.categories.isEmpty)
        #expect(fillApplied.assignments.isEmpty)

        for command in [BudgetTemplateCommand.overwrite, .category("groceries")] {
            let preview = try await database.previewBudgetTemplate(
                command: command,
                month: "2026-07"
            )
            var builder = LocalFirstSyncMessageBuilder()
            let applied = try await database.budgetTemplateApply(
                command: command,
                month: "2026-07",
                builder: &builder
            )
            #expect(preview.categories.map(\.proposed) == applied.assignments.map(\.amount))
        }
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
    }

    private func zeroBudgetAmount(_ categoryID: String, at databaseURL: URL) throws -> Int {
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
            ) ?? 0
        }
    }
}
