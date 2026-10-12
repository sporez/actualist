import Foundation
import Testing
@testable import Actualist

/// Exact outbox-message lists for the writers that create a budget row. A new row
/// gets its identity cells (`month`, `category`) before its own cells and an
/// existing row gets only its own cells, as in Actual. Pins row identity, table
/// routing, message order and the month cell's type (number for amounts, text for carryover).
@Suite("Budget row identity messages")
@MainActor
struct BudgetRowIdentityMessageTests {
    private let fixtures = LocalFirstActualStoreTests()

    private func lines(_ messages: [ActualSyncDecodedMessage]) -> [String] {
        messages.map { "\($0.dataset)|\($0.row)|\($0.column)|\($0.serializedValue)" }
    }

    private func database(_ extraSQL: String = "") throws -> BudgetDatabase {
        try BudgetDatabase(
            databaseURL: fixtures.makeSQLiteFixture(extraSQL: extraSQL),
            localNodeID: "identity-node"
        )
    }

    @Test func assignToExistingRowWithoutIdColumnDerivesTheRowIDAndWritesOnlyTheAmount() async throws {
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database().assignCategoryBudgetMessages(
            categoryID: "groceries", budgeted: 12_345, month: "2026-07", builder: &builder
        )
        #expect(lines(messages) == ["zero_budgets|202607-groceries|amount|N:12345"])
    }

    @Test func assignToNewRowAddsIdentityThenAmountWithoutCarryover() async throws {
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database().assignCategoryBudgetMessages(
            categoryID: "groceries", budgeted: 12_345, month: "2026-08", builder: &builder
        )
        #expect(lines(messages) == [
            "zero_budgets|202608-groceries|month|N:202608",
            "zero_budgets|202608-groceries|category|S:groceries",
            "zero_budgets|202608-groceries|amount|N:12345"
        ])
    }

    @Test func assignReusesAPeerRowIDWhenTheTableHasAnIdColumn() async throws {
        let db = try database("""
            ALTER TABLE zero_budgets ADD COLUMN id TEXT;
            UPDATE zero_budgets SET id = 'peer-groceries-jul';
            """)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await db.assignCategoryBudgetMessages(
            categoryID: "groceries", budgeted: 700, month: "2026-07", builder: &builder
        )
        #expect(lines(messages) == ["zero_budgets|peer-groceries-jul|amount|N:700"])
    }

    @Test func carryoverWritesIdentityOnlyForMonthsWithoutARow() async throws {
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database().categoryCarryoverMessages(
            categoryID: "groceries", carryover: true,
            startMonth: "2026-07", throughMonth: "2026-08", builder: &builder
        )
        #expect(lines(messages) == [
            "zero_budgets|202607-groceries|carryover|N:1",
            "zero_budgets|202608-groceries|month|S:202608",
            "zero_budgets|202608-groceries|category|S:groceries",
            "zero_budgets|202608-groceries|carryover|N:1"
        ])
    }

    @Test func templateApplyWritesAmountThenGoalEachWithItsOwnIdentityCells() async throws {
        let db = try database("""
            ALTER TABLE zero_budgets ADD COLUMN goal INTEGER;
            ALTER TABLE zero_budgets ADD COLUMN long_goal INTEGER;
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories SET goal_def = '[{"type":"simple","monthly":400,"limit":null,"priority":0,"directive":"template"}]' WHERE id = 'groceries';
            """)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await db.budgetTemplateApply(
            command: .category("groceries"), month: "2026-08", builder: &builder
        ).messages
        #expect(lines(messages) == [
            "zero_budgets|202608-groceries|month|N:202608",
            "zero_budgets|202608-groceries|category|S:groceries",
            "zero_budgets|202608-groceries|amount|N:40000",
            "zero_budgets|202608-groceries|month|N:202608",
            "zero_budgets|202608-groceries|category|S:groceries",
            "zero_budgets|202608-groceries|carryover|N:0",
            "zero_budgets|202608-groceries|goal|N:40000",
            "zero_budgets|202608-groceries|long_goal|0:"
        ])
    }

    private static let holdFixtureSQL = """
        CREATE TABLE zero_budget_months (id TEXT PRIMARY KEY, buffered INTEGER);
        INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 10);
        INSERT INTO categories VALUES ('salary', 'Salary', 'income-group', 1, 0, 0, 1);
        INSERT INTO category_mapping VALUES ('salary', 'salary');
        INSERT INTO transactions VALUES ('salary-jul', 'checking', 20260701, 200000, 'salary', 0, NULL, 0);
        """

    @Test func holdOnANewIncomeRowWritesBufferIdentityThenCarryover() async throws {
        let db = try database(Self.holdFixtureSQL)
        let review = try await db.budgetHoldReview(month: "2026-07")
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await db.budgetHoldMessages(
            command: .hold(amount: 40_000), review: review, builder: &builder
        )
        #expect(lines(messages) == [
            "zero_budget_months|2026-07|buffered|N:40000",
            "zero_budgets|202607-salary|month|S:202607",
            "zero_budgets|202607-salary|category|S:salary",
            "zero_budgets|202607-salary|carryover|N:0"
        ])
    }

    @Test func holdOnAnExistingIncomeRowWritesOnlyBufferAndCarryover() async throws {
        let db = try database(Self.holdFixtureSQL + "INSERT INTO zero_budgets VALUES (202607, 'salary', 0, 0);")
        let review = try await db.budgetHoldReview(month: "2026-07")
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await db.budgetHoldMessages(
            command: .hold(amount: 40_000), review: review, builder: &builder
        )
        #expect(lines(messages) == [
            "zero_budget_months|2026-07|buffered|N:40000",
            "zero_budgets|202607-salary|carryover|N:0"
        ])
    }
}
