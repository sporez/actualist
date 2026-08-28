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
            currentMonth: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 15_000)
    }

    @Test func budgetTemplateAverageShortensSixMonthWindowToTwoMonthsOfHistory() async throws {
        let fixtureURL = try makeAverageHistoryFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("dining"),
            month: "2026-07",
            currentMonth: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try zeroBudgetAmount("dining", at: fixtureURL) == 15_000)
    }

    @Test func budgetTemplateAverageIncludesGapsAfterFirstHistoryMonth() async throws {
        let fixtureURL = try makeAverageHistoryFixture(
            extraSQL: """
                INSERT INTO transactions VALUES ('april-d', 'checking', 20260403, -30000, 'dining', 0, NULL, 0);
                INSERT INTO transactions VALUES ('june-d', 'checking', 20260603, -20000, 'dining', 0, NULL, 0);
                """
        )
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("dining"),
            month: "2026-07",
            currentMonth: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        // June -200, May 0, April -300 over the 3-month first-history window.
        #expect(try zeroBudgetAmount("dining", at: fixtureURL) == 16_667)
    }

    @Test func budgetTemplateAverageAnchorsFutureMonthsToCompletedHistory() async throws {
        let fixtureURL = try makeAverageHistoryFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("dining"),
            month: "2026-11",
            currentMonth: "2026-08",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        // Start is July (last completed), then June and May. July has no dining activity.
        #expect(try zeroBudgetAmount("dining", month: 202611, at: fixtureURL) == 10_000)
    }

    @Test func budgetTemplateAverageKeepsNetPositiveRefundHistory() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
            VALUES ('dining', 'Dining', 'group', 0, 0, 0, 2, '[{"directive":"template","type":"average","numMonths":6,"priority":0}]');
            INSERT INTO category_mapping VALUES ('dining', 'dining');
            INSERT INTO transactions VALUES ('may-d', 'checking', 20260503, 10000, 'dining', 0, NULL, 0);
            INSERT INTO transactions VALUES ('june-d', 'checking', 20260603, 20000, 'dining', 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("dining"),
            month: "2026-07",
            currentMonth: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try zeroBudgetAmount("dining", at: fixtureURL) == 15_000)
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

    @Test func budgetTemplateScheduleIdWritesThePayMonthAmount() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: scheduleTemplateSQL(
            goalDef: #"[{"directive":"template","type":"schedule","name":"Rent","scheduleId":"rent-sched","priority":0}]"#,
            schedules: [("rent-sched", "Rent", -125000)]
        ))
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

    @Test func budgetTemplateRenamedScheduleStillResolvesByScheduleId() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: scheduleTemplateSQL(
            goalDef: #"[{"directive":"template","type":"schedule","name":"Rent","scheduleId":"rent-sched","priority":0}]"#,
            schedules: [("rent-sched", "Housing", -125000)]
        ))
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

    @Test func budgetTemplateDuplicateScheduleNamesResolveTheIntendedId() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: scheduleTemplateSQL(
            goalDef: #"[{"directive":"template","type":"schedule","name":"Rent","scheduleId":"rent-b","priority":0}]"#,
            schedules: [
                ("rent-a", "Rent", -125000),
                ("rent-b", "Rent", -50000)
            ]
        ))
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
    }

    @Test func budgetTemplateInvalidScheduleIdDoesNotFallBackToName() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: scheduleTemplateSQL(
            goalDef: #"[{"directive":"template","type":"schedule","name":"Rent","scheduleId":"missing","priority":0}]"#,
            schedules: [("rent-sched", "Rent", -125000)]
        ))
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        do {
            _ = try await database.budgetTemplateMessages(
                command: .category("groceries"),
                month: "2026-07",
                builder: &builder
            )
            Issue.record("Expected an invalid scheduleId to be refused")
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            #expect(reason.contains("Schedule Rent does not exist"))
        }
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        #expect(try storedCRDTMessages(at: fixtureURL).isEmpty)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
    }

    @Test func budgetTemplateMissingScheduleIdWritesNothing() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: scheduleTemplateSQL(
            goalDef: #"[{"directive":"template","type":"schedule","scheduleId":"missing","priority":0}]"#,
            schedules: [("rent-sched", "Rent", -125000)]
        ))
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        do {
            _ = try await database.budgetTemplateMessages(
                command: .category("groceries"),
                month: "2026-07",
                builder: &builder
            )
            Issue.record("Expected a missing scheduleId to be refused")
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            #expect(reason.contains("Schedule missing does not exist"))
        }
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        #expect(try storedCRDTMessages(at: fixtureURL).isEmpty)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
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
            \(trackingBudgetSQL())
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
        #expect(messages.contains { message in
            message.dataset == "reflect_budgets" && message.row.contains("salary")
        })
        #expect(!messages.contains { $0.dataset == "zero_budgets" })
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try reflectBudgetAmount("salary", at: fixtureURL) == 10_000)
        #expect(try zeroBudgetAmount("salary", at: fixtureURL) == nil)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
    }

    @Test func budgetTemplateTrackingFromLastMonthRequiresCarryover() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            \(trackingBudgetSQL())
            INSERT INTO zero_budgets VALUES (202606, 'groceries', 10000, 1);
            INSERT INTO reflect_budgets VALUES ('202606-groceries', 202606, 'groceries', 10000, 0);
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
        #expect(try reflectBudgetAmount("groceries", at: fixtureURL) == 20_000)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
        #expect(try budgetAmount("groceries", table: "zero_budgets", month: 202606, at: fixtureURL) == 10_000)
    }

    @Test func budgetTemplateTrackingFillEmptyReadsReflectNotZero() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            \(trackingBudgetSQL())
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":50,"priority":0}]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .fillEmpty,
            month: "2026-07",
            builder: &builder
        )
        #expect(messages.contains { message in
            message.dataset == "reflect_budgets" && message.column == "amount"
        })
        #expect(!messages.contains { $0.dataset == "zero_budgets" })
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try reflectBudgetAmount("groceries", at: fixtureURL) == 5_000)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
    }

    @Test func budgetTemplateTrackingCopyUsesReflectHistoryNotZero() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            \(trackingBudgetSQL())
            INSERT INTO zero_budgets VALUES (202606, 'groceries', 99999, 0);
            INSERT INTO reflect_budgets VALUES ('202606-groceries', 202606, 'groceries', 12345, 0);
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"copy","lookBack":1,"priority":0}]'
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
        #expect(try reflectBudgetAmount("groceries", at: fixtureURL) == 12_345)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
        #expect(try budgetAmount("groceries", table: "zero_budgets", month: 202606, at: fixtureURL) == 99_999)
    }

    @Test func budgetTemplateTrackingGoalWritesReflectNotZero() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            \(trackingBudgetSQL(includeGoals: true))
            UPDATE zero_budgets SET goal = 1, long_goal = 1 WHERE category = 'groceries';
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
        #expect(messages.contains { message in
            message.dataset == "reflect_budgets" && message.column == "goal"
        })
        #expect(!messages.contains { $0.dataset == "zero_budgets" })
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try reflectBudgetAmount("groceries", at: fixtureURL) == 5_000)
        #expect(try budgetGoal("groceries", table: "reflect_budgets", at: fixtureURL) == 50_000)
        #expect(try budgetLongGoal("groceries", table: "reflect_budgets", at: fixtureURL) == 1)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
        #expect(try zeroBudgetGoal("groceries", at: fixtureURL) == 1)
        #expect(try zeroBudgetLongGoal("groceries", at: fixtureURL) == 1)
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

    @Test func budgetTemplateRemainderWithoutHoldUsesEnvelopeToBudget() async throws {
        let result = try await applyEnvelopeTemplate(
            extraSQL: envelopeAvailableFundsSQL(hold: nil) + bufferTemplateSQL(
                "[{\"directive\":\"template\",\"type\":\"remainder\",\"weight\":1,\"priority\":null}]"
            )
        )
        #expect(result.toBudgetBefore == 50_000)
        #expect(result.amount == result.toBudgetBefore)
        #expect(result.toBudgetAfter == 0)
    }

    @Test func budgetTemplateRemainderRespectsHoldForNextMonth() async throws {
        let result = try await applyEnvelopeTemplate(
            extraSQL: envelopeAvailableFundsSQL(hold: 25_000) + bufferTemplateSQL(
                "[{\"directive\":\"template\",\"type\":\"remainder\",\"weight\":1,\"priority\":null}]"
            )
        )
        #expect(result.toBudgetBefore == 25_000)
        #expect(result.amount == result.toBudgetBefore)
        #expect(result.toBudgetAfter == 0)
    }

    @Test func budgetTemplatePriorityRespectsHoldForNextMonth() async throws {
        let result = try await applyEnvelopeTemplate(
            extraSQL: envelopeAvailableFundsSQL(hold: 25_000) + bufferTemplateSQL(
                "[{\"directive\":\"template\",\"type\":\"simple\",\"monthly\":1000,\"priority\":1}]"
            )
        )
        #expect(result.toBudgetBefore == 25_000)
        #expect(result.amount == result.toBudgetBefore)
    }

    @Test func budgetTemplatePercentageOfAvailableFundsRespectsHoldForNextMonth() async throws {
        let result = try await applyEnvelopeTemplate(
            extraSQL: envelopeAvailableFundsSQL(hold: 25_000) + bufferTemplateSQL(
                "[{\"directive\":\"template\",\"type\":\"percentage\",\"percent\":10,\"previous\":false,\"category\":\"available funds\",\"priority\":0}]"
            )
        )
        #expect(result.toBudgetBefore == 25_000)
        #expect(
            result.amount == (try BudgetTemplateEngine.actualRound(Double(result.toBudgetBefore) * 0.1))
        )
    }

    @Test func budgetTemplateOverwriteAddsBackHeldCategoryBudget() async throws {
        let result = try await applyEnvelopeTemplate(
            extraSQL: envelopeAvailableFundsSQL(hold: 25_000) + """
                UPDATE categories
                SET goal_def = '[{\"directive\":\"template\",\"type\":\"remainder\",\"weight\":1,\"priority\":null}]'
                WHERE id = 'groceries';
                """,
            categoryID: "groceries"
        )
        #expect(result.toBudgetBefore == 25_000)
        #expect(result.amount == result.toBudgetBefore + 50_000)
    }

    @Test func budgetTemplateTrackingStartsFromTotalSavedNotEnvelopeToBudget() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            \(trackingBudgetSQL())
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-group', 1, 0, 0, 0, NULL);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions VALUES ('pay', 'checking', 20260701, 200000, 'salary', 0, NULL, 0);
            INSERT INTO reflect_budgets VALUES ('202607-salary', 202607, 'salary', 10000, 0);
            INSERT INTO reflect_budgets VALUES ('202607-groceries', 202607, 'groceries', 3000, 0);
            \(bufferTemplateSQL(
                "[{\"directive\":\"template\",\"type\":\"remainder\",\"weight\":1,\"priority\":null}]"
            ))
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let before = try await database.fetchBudgetMonth(month: "2026-07")
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .overwrite,
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        let amount = try reflectBudgetAmount("buffer", at: fixtureURL)
        #expect(before.toBudget != 7_000)
        #expect(amount == 7_000)
    }

    @Test func budgetTemplateTrackingOverwriteAddsBackCurrentBudget() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            \(trackingBudgetSQL())
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-group', 1, 0, 0, 0, NULL);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions VALUES ('pay', 'checking', 20260701, 200000, 'salary', 0, NULL, 0);
            INSERT INTO reflect_budgets VALUES ('202607-salary', 202607, 'salary', 10000, 0);
            INSERT INTO reflect_budgets VALUES ('202607-groceries', 202607, 'groceries', 3000, 0);
            UPDATE categories
            SET goal_def = '[{\"directive\":\"template\",\"type\":\"remainder\",\"weight\":1,\"priority\":null}]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .overwrite,
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        #expect(try reflectBudgetAmount("groceries", at: fixtureURL) == 10_000)
    }

    private func trackingBudgetSQL(includeGoals: Bool = false) -> String {
        var sql = """
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('budgetType', 'tracking');
            CREATE TABLE reflect_budgets (
                id TEXT PRIMARY KEY,
                month INTEGER,
                category TEXT,
                amount INTEGER,
                carryover INTEGER
            );
            """
        if includeGoals {
            sql += """
                ALTER TABLE reflect_budgets ADD COLUMN goal INTEGER;
                ALTER TABLE reflect_budgets ADD COLUMN long_goal INTEGER;
                ALTER TABLE zero_budgets ADD COLUMN goal INTEGER;
                ALTER TABLE zero_budgets ADD COLUMN long_goal INTEGER;
                """
        }
        return sql
    }

    private func envelopeAvailableFundsSQL(hold: Int?) -> String {
        var sql = """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO category_groups VALUES ('income-grp', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-grp', 1, 0, 0, 2, NULL);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions VALUES ('inc-jul', 'checking', 20260710, 100000, 'salary', 0, NULL, 0);
            """
        if let hold {
            sql += """
                CREATE TABLE zero_budget_months (id TEXT PRIMARY KEY, buffered INTEGER);
                INSERT INTO zero_budget_months VALUES ('2026-07', \(hold));
                """
        }
        return sql
    }

    private func bufferTemplateSQL(_ goalDef: String) -> String {
        """
        INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
        VALUES ('buffer', 'Buffer', 'group', 0, 0, 0, 2, '\(goalDef)');
        INSERT INTO category_mapping VALUES ('buffer', 'buffer');
        """
    }

    private func makeAverageHistoryFixture(
        extraSQL: String = """
            INSERT INTO transactions VALUES ('may-d', 'checking', 20260503, -10000, 'dining', 0, NULL, 0);
            INSERT INTO transactions VALUES ('june-d', 'checking', 20260603, -20000, 'dining', 0, NULL, 0);
            """
    ) throws -> URL {
        try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
            VALUES ('dining', 'Dining', 'group', 0, 0, 0, 2, '[{\"directive\":\"template\",\"type\":\"average\",\"numMonths\":6,\"priority\":0}]');
            INSERT INTO category_mapping VALUES ('dining', 'dining');
            \(extraSQL)
            """)
    }

    private func applyEnvelopeTemplate(
        extraSQL: String,
        categoryID: String = "buffer"
    ) async throws -> (toBudgetBefore: Int, amount: Int?, toBudgetAfter: Int) {
        let fixtureURL = try makeSQLiteFixture(extraSQL: extraSQL)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let before = try await database.fetchBudgetMonth(month: "2026-07")
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .overwrite,
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        let after = try await database.fetchBudgetMonth(month: "2026-07")
        return (
            before.toBudget,
            try zeroBudgetAmount(categoryID, at: fixtureURL),
            after.toBudget
        )
    }

    private func zeroBudgetAmount(
        _ categoryID: String,
        month: Int = 202607,
        at databaseURL: URL
    ) throws -> Int? {
        try budgetAmount(categoryID, table: "zero_budgets", month: month, at: databaseURL)
    }

    private func reflectBudgetAmount(_ categoryID: String, at databaseURL: URL) throws -> Int? {
        try budgetAmount(categoryID, table: "reflect_budgets", at: databaseURL)
    }

    private func budgetAmount(
        _ categoryID: String,
        table: String,
        month: Int = 202607,
        at databaseURL: URL
    ) throws -> Int? {
        let queue = try DatabaseQueue(path: databaseURL.path)
        return try queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT amount
                    FROM \(table)
                    WHERE category = ? AND month = ?
                    """,
                arguments: [categoryID, month]
            )
        }
    }

    private func zeroBudgetGoal(_ categoryID: String, at databaseURL: URL) throws -> Int? {
        try budgetColumn("goal", categoryID: categoryID, table: "zero_budgets", at: databaseURL)
    }

    private func zeroBudgetLongGoal(_ categoryID: String, at databaseURL: URL) throws -> Int? {
        try budgetColumn("long_goal", categoryID: categoryID, table: "zero_budgets", at: databaseURL)
    }

    private func budgetGoal(_ categoryID: String, table: String, at databaseURL: URL) throws -> Int? {
        try budgetColumn("goal", categoryID: categoryID, table: table, at: databaseURL)
    }

    private func budgetLongGoal(_ categoryID: String, table: String, at databaseURL: URL) throws -> Int? {
        try budgetColumn("long_goal", categoryID: categoryID, table: table, at: databaseURL)
    }

    private func budgetColumn(
        _ column: String,
        categoryID: String,
        table: String,
        at databaseURL: URL
    ) throws -> Int? {
        let queue = try DatabaseQueue(path: databaseURL.path)
        return try queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT \(column)
                    FROM \(table)
                    WHERE category = ? AND month = 202607
                    """,
                arguments: [categoryID]
            )
        }
    }

    private func scheduleTemplateSQL(
        goalDef: String,
        schedules: [(id: String, name: String, amount: Int)]
    ) -> String {
        var sql = """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '\(goalDef)'
            WHERE id = 'groceries';
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            CREATE TABLE schedules (
                id TEXT PRIMARY KEY,
                name TEXT,
                rule TEXT,
                completed INTEGER,
                tombstone INTEGER
            );
            """
        for schedule in schedules {
            let ruleID = "\(schedule.id)-rule"
            sql += """
                INSERT INTO rules VALUES (
                    '\(ruleID)',
                    '[{"op":"is","field":"amount","value":\(schedule.amount)},{"op":"is","field":"date","value":{"start":"2026-01-01","frequency":"monthly","interval":1}}]',
                    '[{"op":"link-schedule","value":"\(schedule.id)"}]',
                    0
                );
                INSERT INTO schedules VALUES ('\(schedule.id)', '\(schedule.name)', '\(ruleID)', 0, 0);
                """
        }
        return sql
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
