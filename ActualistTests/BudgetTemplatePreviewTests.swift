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

    @Test func applyPlanCapturesDemandAtClampWithoutDryRun() throws {
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
            skipAvailableClamp: false
        )
        #expect(plan.writes.map(\.amount) == [500])
        #expect(plan.evaluatedDemandByCategory["cat"] == 5_000)
        #expect(plan.evaluatedDemand == 5_000)
        #expect(plan.clampShortfallByCategory["cat"] == 4_500)
        #expect(plan.clampShortfall == 4_500)
    }

    @Test func applyPlanKeepsSignedDemandAndOnlyReportsActualPriorityClamp() throws {
        let negativeLimit = try #require(try engine.decodeSupportedEntries(json: """
            [
              {"directive":"template","type":"simple","limit":{"amount":5,"period":"monthly","hold":false},"priority":0}
            ]
            """))
        let release = try engine.computePlan(
            categories: [
                "release": .init(
                    entries: negativeLimit,
                    fromLastMonth: 1_000,
                    copiedBudgetedByLookBack: [:]
                )
            ],
            orderedCategoryIDs: ["release"],
            monthValue: 202607,
            availableBudget: 0,
            skipAvailableClamp: false
        )
        #expect(release.writes.map(\.amount) == [-500])
        #expect(release.evaluatedDemandByCategory["release"] == -500)
        #expect(release.clampShortfall == 0)

        let priorityZero = try #require(try engine.decodeSupportedEntries(json: """
            [{"directive":"template","type":"simple","monthly":5,"priority":0}]
            """))
        let overbudget = try engine.computePlan(
            categories: [
                "overbudget": .init(
                    entries: priorityZero,
                    fromLastMonth: 0,
                    copiedBudgetedByLookBack: [:]
                )
            ],
            orderedCategoryIDs: ["overbudget"],
            monthValue: 202607,
            availableBudget: 0,
            skipAvailableClamp: false
        )
        #expect(overbudget.writes.map(\.amount) == [500])
        #expect(overbudget.evaluatedDemand == 500)
        #expect(overbudget.clampShortfall == 0)
        #expect(overbudget.leftover == -500)
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
        #expect(preview.categories.first?.name == "Groceries")
        #expect(preview.categories.first?.drafts.count == 1)
        #expect(preview.categories.first?.priorityLevels == [1])
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

    @Test func pairedPreviewKeepsUnfundedRowsAndIsolatedModeErrors() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO categories VALUES (
                'dining', 'Dining', 'group', 0, 0, 0, 2,
                '[{"directive":"template","type":"simple","monthly":30,"priority":1}]'
            );
            INSERT INTO category_mapping VALUES ('dining', 'dining');
            UPDATE categories SET goal_def = 'not-json' WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")

        let pair = try await database.previewBudgetTemplatePair(month: "2026-07")
        guard case .ready(let fill) = pair.fillEmpty else {
            Issue.record("Expected Fill Empty preview to be ready")
            return
        }
        guard case .failed(let errorMessage) = pair.overwrite else {
            Issue.record("Expected Overwrite preview to fail")
            return
        }
        #expect(!errorMessage.isEmpty)
        let dining = try #require(fill.categories.first { $0.categoryID == "dining" })
        #expect(dining.current == 0)
        #expect(dining.proposed == 0)
        #expect(dining.evaluatedDemand == 3_000)
        #expect(dining.shortfall == 3_000)
        #expect(fill.stillNeeded == 3_000)
        #expect(try zeroBudgetAmount("dining", at: fixtureURL) == 0)
    }

    @Test func previewReportsNetFundingPartialClampAndPersistsAppliedBalance() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 2);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
            VALUES ('salary', 'Salary', 'income', 1, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            DELETE FROM zero_budgets;
            INSERT INTO zero_budgets VALUES (202607, 'groceries', 0, 0);
            DELETE FROM transactions;
            INSERT INTO transactions VALUES ('income-txn', 'checking', 20260703, 300, 'salary', 0, NULL, 0);
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":5,"priority":1}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")

        let preview = try await database.previewBudgetTemplate(
            command: .overwrite,
            month: "2026-07"
        )
        let groceries = try #require(preview.categories.first { $0.categoryID == "groceries" })
        #expect(preview.evaluatedDemand == 500)
        #expect(preview.fundingRequired == 500)
        #expect(preview.assigned == 300)
        #expect(preview.stillNeeded == 200)
        #expect(preview.availableBefore == 300)
        #expect(preview.availableAfter == 0)
        #expect(groceries.current == 0)
        #expect(groceries.proposed == 300)
        #expect(groceries.evaluatedDemand == 500)
        #expect(groceries.shortfall == 200)
        #expect(groceries.metric.kind == .available)
        #expect(groceries.metric.before == 0)
        #expect(groceries.metric.after == 300)

        var builder = LocalFirstSyncMessageBuilder()
        let applied = try await database.budgetTemplateApply(
            command: .overwrite,
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(applied.messages)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 300)
    }

    @Test func overwriteFundingReusesAssignmentsAndReportsAvailableBeforeAfter() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 2);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
            VALUES ('salary', 'Salary', 'income', 1, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            UPDATE zero_budgets SET amount = 100, carryover = 0 WHERE category = 'groceries';
            DELETE FROM transactions;
            INSERT INTO transactions VALUES ('income-txn', 'checking', 20260703, 175, 'salary', 0, NULL, 0);
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":2,"priority":1}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")

        let preview = try await database.previewBudgetTemplate(
            command: .overwrite,
            month: "2026-07"
        )
        let groceries = try #require(preview.categories.first { $0.categoryID == "groceries" })
        #expect(preview.evaluatedDemand == 200)
        #expect(preview.fundingRequired == 100)
        #expect(preview.assigned == 75)
        #expect(preview.stillNeeded == 25)
        #expect(preview.availableBefore == 75)
        #expect(preview.availableAfter == 0)
        #expect(groceries.current == 100)
        #expect(groceries.proposed == 175)
        #expect(groceries.shortfall == 25)
        #expect(groceries.metric.before == 100)
        #expect(groceries.metric.after == 175)
    }

    @Test func releaseAndNewTargetReuseReleasedAssignmentBeforeFunding() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
            VALUES ('dining', 'Dining', 'group', 0, 0, 0, 2);
            INSERT INTO category_mapping VALUES ('dining', 'dining');
            INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 2);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
            VALUES ('salary', 'Salary', 'income', 1, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            DELETE FROM zero_budgets;
            INSERT INTO zero_budgets VALUES (202607, 'groceries', 100, 0);
            INSERT INTO zero_budgets VALUES (202607, 'dining', 0, 0);
            DELETE FROM transactions;
            INSERT INTO transactions VALUES ('income-txn', 'checking', 20260703, 100, 'salary', 0, NULL, 0);
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":0,"priority":1}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'groceries';
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":3,"priority":1}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'dining';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")

        let preview = try await database.previewBudgetTemplate(
            command: .overwrite,
            month: "2026-07"
        )
        let groceries = try #require(preview.categories.first { $0.categoryID == "groceries" })
        let dining = try #require(preview.categories.first { $0.categoryID == "dining" })
        #expect(preview.evaluatedDemand == 300)
        #expect(preview.fundingRequired == 200)
        #expect(preview.assigned == 100)
        #expect(preview.released == 100)
        #expect(preview.stillNeeded == 200)
        #expect(preview.availableBefore == 0)
        #expect(preview.availableAfter == 0)
        #expect(groceries.current == 100)
        #expect(groceries.proposed == 0)
        #expect(dining.current == 0)
        #expect(dining.proposed == 100)
        #expect(dining.shortfall == 200)
    }

    @Test func sqlitePreviewKeepsNegativeLimitReleaseSignedAndUnfundedFree() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            INSERT INTO zero_budgets VALUES (202606, 'groceries', 1000, 1);
            UPDATE zero_budgets SET amount = 0 WHERE month = 202607 AND category = 'groceries';
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","limit":{"amount":5,"period":"monthly","hold":false},"priority":0}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")

        let preview = try await database.previewBudgetTemplate(
            command: .overwrite,
            month: "2026-07"
        )
        let groceries = try #require(preview.categories.first { $0.categoryID == "groceries" })
        #expect(preview.fundingRequired == 0)
        #expect(preview.stillNeeded == 0)
        #expect(preview.released == 500)
        #expect(preview.availableBefore == -1_000)
        #expect(preview.availableAfter == -500)
        #expect(groceries.current == 0)
        #expect(groceries.proposed == -500)
        #expect(groceries.evaluatedDemand == -500)
        #expect(groceries.priorityLevels == [0])
        #expect(groceries.shortfall == 0)
        #expect(groceries.metric.after == -11_845)

        var builder = LocalFirstSyncMessageBuilder()
        let applied = try await database.budgetTemplateApply(
            command: .overwrite,
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(applied.messages)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == -500)
    }

    @Test func goalOnlyPreviewReportsNonMoneyUpdateAndUsesBudgetCurrency() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE zero_budgets ADD COLUMN goal INTEGER;
            ALTER TABLE zero_budgets ADD COLUMN long_goal INTEGER;
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('defaultCurrencyCode', 'jpy');
            INSERT INTO preferences VALUES ('hideFraction', 'true');
            UPDATE categories SET goal_def =
                '[{"directive":"goal","type":"goal","amount":600,"priority":null}]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")

        let pair = try await database.previewBudgetTemplatePair(month: "2026-07")
        guard case .ready(let fill) = pair.fillEmpty else {
            Issue.record("Expected Fill Empty preview to be ready")
            return
        }
        guard case .ready(let overwrite) = pair.overwrite else {
            Issue.record("Expected Overwrite preview to be ready")
            return
        }
        #expect(fill.categories.isEmpty)
        let groceries = try #require(overwrite.categories.first { $0.categoryID == "groceries" })
        #expect(overwrite.currency == BudgetCurrency.catalog(code: "JPY", hideFraction: true))
        #expect(overwrite.assigned == 0)
        #expect(overwrite.released == 0)
        #expect(overwrite.hasNonMoneyUpdates)
        #expect(overwrite.categories.contains { $0.isGoalOnlyUpdate })
        #expect(groceries.current == groceries.proposed)
        #expect(groceries.isGoalOnlyUpdate)
        #expect(groceries.priorityLevels.isEmpty)
        #expect(groceries.goalBefore == nil)
        #expect(groceries.goalAfter == 600)
        #expect(groceries.metric.kind == .available)
        #expect(groceries.metric.before == groceries.metric.after)
    }

    @Test func overwriteOmitsFundedUnchangedRows() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            ALTER TABLE zero_budgets ADD COLUMN goal INTEGER;
            INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 2);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
            VALUES ('salary', 'Salary', 'income', 1, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            UPDATE zero_budgets SET amount = 500, carryover = 0, goal = 500
            WHERE month = 202607 AND category = 'groceries';
            DELETE FROM transactions;
            INSERT INTO transactions VALUES ('income-txn', 'checking', 20260703, 1000, 'salary', 0, NULL, 0);
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":5,"priority":1}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")

        let preview = try await database.previewBudgetTemplate(
            command: .overwrite,
            month: "2026-07"
        )
        #expect(preview.evaluatedDemand == 500)
        #expect(preview.fundingRequired == 0)
        #expect(preview.assigned == 0)
        #expect(preview.stillNeeded == 0)
        #expect(preview.categories.isEmpty)
        #expect(preview.hasEligibleTemplates)
    }

    @Test func trackingIncomeFundsExpensesAndProjectsActualTotalSaved() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('budgetType', 'tracking');
            CREATE TABLE reflect_budgets (
                id TEXT PRIMARY KEY, month INTEGER, category TEXT,
                amount INTEGER, carryover INTEGER
            );
            INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 2);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
            VALUES ('salary', 'Salary', 'income', 1, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            UPDATE categories SET goal_def =
                '[{"directive":"template","type":"simple","monthly":5,"priority":1}]'
            WHERE id = 'salary';
            UPDATE categories SET goal_def =
                '[{"directive":"template","type":"simple","monthly":2,"priority":2}]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let preview = try await database.previewBudgetTemplate(
            command: .overwrite, month: "2026-07"
        )
        #expect(preview.isTrackingBudget)
        #expect(preview.fundingRequired == 0)
        #expect(preview.availableBefore == 0)
        #expect(preview.availableAfter == 300)
        #expect(preview.stillNeeded == 0)

        var builder = LocalFirstSyncMessageBuilder()
        let apply = try await database.budgetTemplateApply(
            command: .overwrite, month: "2026-07", builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(apply.messages)
        let month = try await database.fetchBudgetMonth(month: "2026-07")
        #expect(month.trackingSummary?.plannedSavings == preview.availableAfter)
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
