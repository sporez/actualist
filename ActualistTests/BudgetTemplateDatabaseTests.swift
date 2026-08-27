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

    @Test func budgetTemplateMixedGoalAndTemplateWritesNothing() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[
                {"directive":"goal","type":"goal","amount":500,"priority":null},
                {"directive":"template","type":"simple","monthly":50,"priority":0}
            ]'
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
            Issue.record("Expected mixed goal and template to be refused")
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            #expect(reason.localizedCaseInsensitiveContains("goal writes are not supported"))
        }

        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        #expect(try storedCRDTMessages(at: fixtureURL).isEmpty)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
    }

    @Test func budgetTemplateGoalOnlyDoesNotZeroTheCurrentBudget() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
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

        #expect(messages.isEmpty)
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 50_000)
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
}
