import Foundation
import GRDB
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func budgetTemplateTargetedMultiCategoryFollowsCategoryOrderNotGroupOrder() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-group', 1, 0, 0, 0, NULL);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions VALUES ('salary-july', 'checking', 20260701, 60000, 'salary', 0, NULL, 0);
            INSERT INTO category_groups VALUES ('group-a', 'Group A', 0, 0, 0, 0);
            INSERT INTO category_groups VALUES ('group-b', 'Group B', 0, 0, 0, 100);
            INSERT INTO categories VALUES (
                'cat-a', 'Category A', 'group-a', 0, 0, 0, 100,
                '[{"directive":"template","type":"simple","monthly":100,"priority":1}]'
            );
            INSERT INTO category_mapping VALUES ('cat-a', 'cat-a');
            INSERT INTO categories VALUES (
                'cat-b', 'Category B', 'group-b', 0, 0, 0, 1,
                '[{"directive":"template","type":"simple","monthly":100,"priority":1}]'
            );
            INSERT INTO category_mapping VALUES ('cat-b', 'cat-b');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: BudgetTemplateCommand(mode: .overwrite, categoryIDs: ["cat-a", "cat-b"]),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)

        #expect(try zeroBudgetAmount("cat-b", at: fixtureURL) == 10_000)
        #expect(try zeroBudgetAmount("cat-a", at: fixtureURL) == 0)
    }

    @Test func budgetTemplateNegativeSimpleWritesThroughLocalSyncMessages() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":-103.23,"priority":0}]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        )
        #expect(messages.contains { message in
            message.dataset == "zero_budgets" && message.row.contains("groceries")
        })
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == -10_323)
    }

    @Test func budgetTemplateMixedGoalAndTemplateWritesBudgetAndGoal() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE zero_budgets ADD COLUMN goal INTEGER;
            ALTER TABLE zero_budgets ADD COLUMN long_goal INTEGER;
            UPDATE categories
            SET goal_def = '[
                {"directive":"goal","type":"goal","amount":500,"priority":null},
                {"directive":"template","type":"simple","monthly":50,"priority":0}
            ]'
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
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 5_000)
        #expect(try zeroBudgetGoal("groceries", at: fixtureURL) == 50_000)
        #expect(try zeroBudgetLongGoal("groceries", at: fixtureURL) == 1)
    }

    @Test func budgetTemplateAverageUsesPriorMonthSpending() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"average","numMonths":2,"priority":0}]'
            WHERE id = 'groceries';
            INSERT INTO transactions VALUES ('may', 'checking', 20260503, -10000, 'groceries', 0, NULL, 0);
            INSERT INTO transactions VALUES ('june', 'checking', 20260603, -20000, 'groceries', 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 15_000)
    }

    @Test func budgetTemplatePercentageOfAllIncomeUsesCurrentMonthIncome() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-group', 1, 0, 0, 0, NULL);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions VALUES ('pay', 'checking', 20260701, 60000, 'salary', 0, NULL, 0);
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"percentage","percent":10,"previous":false,"category":"all income","priority":0}]'
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
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 6_000)
    }

    @Test func budgetTemplatePercentageOfUnknownSourceWritesNothing() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"percentage","percent":10,"previous":false,"category":"Food","priority":0}]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        do {
            _ = try await database.budgetTemplateMessages(
                command: .category("groceries"),
                month: "2026-07",
                builder: &builder
            )
            Issue.record("Expected a non-income percentage source to be refused")
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            #expect(reason.contains("Food"))
        }

        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        #expect(try storedCRDTMessages(at: fixtureURL).isEmpty)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
    }

    @Test func budgetTemplateSpendSpreadsRemainingAcrossMonths() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"spend","amount":300,"month":"2026-09","from":"2026-07","priority":0}]'
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
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 10_000)
    }

    @Test func budgetTemplateMonthlyScheduleWritesThePayMonthAmount() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"schedule","name":"Rent","priority":0}]'
            WHERE id = 'groceries';
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'rent-rule',
                '[{"op":"is","field":"amount","value":-125000},{"op":"is","field":"date","value":{"start":"2026-01-01","frequency":"monthly","interval":1}}]',
                '[{"op":"link-schedule","value":"rent-sched"}]',
                0
            );
            CREATE TABLE schedules (
                id TEXT PRIMARY KEY,
                name TEXT,
                rule TEXT,
                completed INTEGER,
                tombstone INTEGER
            );
            INSERT INTO schedules VALUES ('rent-sched', 'Rent', 'rent-rule', 0, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 125_000)
    }

    @Test func budgetTemplateMissingScheduleNameWritesNothing() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"schedule","name":"Rent","priority":0}]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        do {
            _ = try await database.budgetTemplateMessages(
                command: .category("groceries"),
                month: "2026-07",
                builder: &builder
            )
            Issue.record("Expected a missing schedule to be refused")
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            #expect(reason.contains("Schedule Rent does not exist"))
        }
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        #expect(try storedCRDTMessages(at: fixtureURL).isEmpty)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
    }

    @Test func budgetTemplateGoalOnlyKeepsCurrentBudgetAndWritesGoal() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE zero_budgets ADD COLUMN goal INTEGER;
            ALTER TABLE zero_budgets ADD COLUMN long_goal INTEGER;
            UPDATE categories
            SET goal_def = '[{"directive":"goal","type":"goal","amount":500,"priority":null}]'
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
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
        #expect(try zeroBudgetGoal("groceries", at: fixtureURL) == 50_000)
        #expect(try zeroBudgetLongGoal("groceries", at: fixtureURL) == 1)
    }

    @Test func budgetTemplateFillEmptySkipsGoalOnlyWhenAlreadyBudgeted() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE zero_budgets ADD COLUMN goal INTEGER;
            ALTER TABLE zero_budgets ADD COLUMN long_goal INTEGER;
            UPDATE categories
            SET goal_def = '[{"directive":"goal","type":"goal","amount":500,"priority":null}]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .fillEmpty,
            month: "2026-07",
            builder: &builder
        )
        #expect(messages.isEmpty)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
        #expect(try zeroBudgetGoal("groceries", at: fixtureURL) == nil)
    }

    @Test func budgetTemplateClearsOrphanGoalsWhenTemplatesAreGone() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE zero_budgets ADD COLUMN goal INTEGER;
            ALTER TABLE zero_budgets ADD COLUMN long_goal INTEGER;
            UPDATE zero_budgets SET goal = 12345, long_goal = 1 WHERE category = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .overwrite,
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
        #expect(try zeroBudgetGoal("groceries", at: fixtureURL) == nil)
        #expect(try zeroBudgetLongGoal("groceries", at: fixtureURL) == nil)
    }

    @Test func budgetTemplateTrackingIncludesIncomeCategories() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('budgetType', 'tracking');
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES (
                'salary', 'Salary', 'income-group', 1, 0, 0, 0,
                '[{"directive":"template","type":"simple","monthly":100,"priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .overwrite,
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try zeroBudgetAmount("salary", at: fixtureURL) == 10_000)
    }

    @Test func budgetTemplateTrackingFromLastMonthRequiresCarryover() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('budgetType', 'tracking');
            INSERT INTO zero_budgets VALUES (202606, 'groceries', 10000, 0);
            UPDATE categories
            SET goal_def = '[
                {"directive":"template","type":"limit","amount":200,"period":"monthly","hold":false,"priority":null},
                {"directive":"template","type":"refill","priority":0}
            ]'
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
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 20_000)
    }

    @Test func budgetTemplateEnvelopeFromLastMonthUsesLeftoverWithoutTrackingZero() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO zero_budgets VALUES (202606, 'groceries', 10000, 0);
            UPDATE categories
            SET goal_def = '[
                {"directive":"template","type":"limit","amount":200,"period":"monthly","hold":false,"priority":null},
                {"directive":"template","type":"refill","priority":0}
            ]'
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
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 10_000)
    }

    @Test func budgetTemplateTombsOrphanCleanupGroups() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN cleanup_def TEXT;
            CREATE TABLE cleanup_groups (id TEXT PRIMARY KEY, name TEXT, tombstone INTEGER);
            INSERT INTO cleanup_groups VALUES ('used', 'Used', 0);
            INSERT INTO cleanup_groups VALUES ('orphan-group', 'Orphan', 0);
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":10,"priority":0}]',
                cleanup_def = '[{"role":"source","groupId":"used","weight":1}]'
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
        #expect(try cleanupGroupTombstone("used", at: fixtureURL) == 0)
        #expect(try cleanupGroupTombstone("orphan-group", at: fixtureURL) == 1)
    }

    private func zeroBudgetAmount(_ categoryID: String, at databaseURL: URL) throws -> Int? {
        let queue = try DatabaseQueue(path: databaseURL.path)
        return try queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT amount
                    FROM zero_budgets
                    WHERE category = ? AND month = 202607
                    """,
                arguments: [categoryID]
            )
        }
    }

    private func zeroBudgetGoal(_ categoryID: String, at databaseURL: URL) throws -> Int? {
        try zeroBudgetColumn("goal", categoryID: categoryID, at: databaseURL)
    }

    private func zeroBudgetLongGoal(_ categoryID: String, at databaseURL: URL) throws -> Int? {
        try zeroBudgetColumn("long_goal", categoryID: categoryID, at: databaseURL)
    }

    private func zeroBudgetColumn(
        _ column: String,
        categoryID: String,
        at databaseURL: URL
    ) throws -> Int? {
        let queue = try DatabaseQueue(path: databaseURL.path)
        return try queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT \(column)
                    FROM zero_budgets
                    WHERE category = ? AND month = 202607
                    """,
                arguments: [categoryID]
            )
        }
    }

    private func cleanupGroupTombstone(_ groupID: String, at databaseURL: URL) throws -> Int? {
        let queue = try DatabaseQueue(path: databaseURL.path)
        return try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT tombstone FROM cleanup_groups WHERE id = ?",
                arguments: [groupID]
            )
        }
    }
}
