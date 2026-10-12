import Foundation
import Testing
@testable import Actualist

/// Covers are limited to what their source has left, and a move from To Budget into a category to what To Budget
/// has, as in Actual's cover and transfer-available handlers. A category-to-category move is never limited. Amounts are Actual minor units.
@Suite("Budget cover limit")
@MainActor
struct BudgetCoverLimitTests {
    private let fixtures = LocalFirstActualStoreTests()

    @Test func coverIsLimitedToTheSourceAndDroppedWhenTheSourceHasNothing() {
        let cover = BudgetMoveMoneyCommand(fromCategoryID: "dining", toCategoryID: "groceries", amount: 10_000, kind: .cover)
        #expect(cover.limited(toSourceAvailable: 25_000) == cover)
        #expect(cover.limited(toSourceAvailable: 4_000)?.amount == 4_000)
        #expect(cover.limited(toSourceAvailable: 0) == nil)
        #expect(cover.limited(toSourceAvailable: -500) == nil)

        let move = BudgetMoveMoneyCommand(fromCategoryID: "dining", toCategoryID: "groceries", amount: 10_000)
        #expect(move.limited(toSourceAvailable: 0) == move)
        #expect(move.limited(toSourceAvailable: 4_000) == move)
    }

    @Test func coverFromToBudgetIsLimitedToToBudgetAndPlainMoveIsNot() async throws {
        let url = try fixtures.makeSQLiteFixture(extraSQL: """
            CREATE TABLE zero_budget_months (id TEXT PRIMARY KEY, buffered INTEGER);
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 10);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-group', 1, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions VALUES ('salary-jul', 'checking', 20260701, 200000, 'salary', 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "cover-limit")
        let toBudget = try await database.fetchBudgetMonth(month: "2026-07").toBudget
        #expect(toBudget > 0)
        let mode = try await database.requireBudgetMode(nil)

        let cover = BudgetMoveMoneyCommand(fromCategoryID: nil, toCategoryID: "groceries", amount: toBudget + 5_000, kind: .cover)
        let move = BudgetMoveMoneyCommand(fromCategoryID: nil, toCategoryID: "groceries", amount: toBudget + 5_000)
        let resolved = try await database.commitUserActionPlan(source: .ui, expectedMode: mode) { budget, db in
            let resolved = try budget.resolvedMoveMoneyCommands([cover, move, cover], month: "2026-07", db: db)
            return UserActionPlan(drafts: [], descriptor: nil, outcome: resolved)
        }.outcome

        // The first cover takes all of To Budget; the second finds nothing left; the plain move is untouched.
        #expect(resolved.map(\.amount) == [toBudget, toBudget + 5_000])
        #expect(resolved.map(\.kind) == [.cover, .move])
    }

    @Test func moveFromToBudgetIntoACategoryIsATransferAvailable() {
        #expect(BudgetMoveMoneyCommand.move(fromCategoryID: nil, toCategoryID: "groceries", amount: 100).kind == .transferAvailable)
        #expect(BudgetMoveMoneyCommand.move(fromCategoryID: "dining", toCategoryID: "groceries", amount: 100).kind == .move)
        #expect(BudgetMoveMoneyCommand.move(fromCategoryID: "dining", toCategoryID: nil, amount: 100).kind == .move)

        let transfer = BudgetMoveMoneyCommand.move(fromCategoryID: nil, toCategoryID: "groceries", amount: 10_000)
        #expect(transfer.limited(toSourceAvailable: 25_000)?.amount == 10_000)
        #expect(transfer.limited(toSourceAvailable: 4_000)?.amount == 4_000)
        // Actual still writes the destination's budget row for nothing, so the command survives at zero.
        #expect(transfer.limited(toSourceAvailable: 0)?.amount == 0)
        #expect(transfer.limited(toSourceAvailable: -500)?.amount == 0)
    }

    @Test func transferAvailableCommitsTheClampedAmountAndAZeroRowWhenToBudgetIsNotPositive() async throws {
        let url = try fixtures.makeSQLiteFixture(extraSQL: """
            CREATE TABLE zero_budget_months (id TEXT PRIMARY KEY, buffered INTEGER);
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 10);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-group', 1, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions VALUES ('salary-jul', 'checking', 20260701, 200000, 'salary', 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "transfer-available")
        let toBudget = try await database.fetchBudgetMonth(month: "2026-07").toBudget
        #expect(toBudget > 0)
        let mode = try await database.requireBudgetMode(nil)

        let transfer = BudgetMoveMoneyCommand.move(fromCategoryID: nil, toCategoryID: "groceries", amount: toBudget + 5_000)
        let plan = try await database.commitUserActionPlan(source: .ui, expectedMode: mode) { budget, db in
            var builder = LocalFirstSyncMessageBuilder()
            let resolved = try budget.resolvedMoveMoneyCommands([transfer, transfer], month: "2026-07", db: db)
            let drafts = try budget.moveMoneyMessages(commands: resolved, month: "2026-07", db: db, builder: &builder)
            return UserActionPlan(drafts: drafts, descriptor: nil, outcome: resolved)
        }.outcome

        // The first takes all of To Budget; the second finds nothing left and keeps a zero amount.
        #expect(plan.map(\.amount) == [toBudget, 0])

        let zero = try await database.commitUserActionPlan(source: .ui, expectedMode: mode) { budget, db in
            var builder = LocalFirstSyncMessageBuilder()
            let none = BudgetMoveMoneyCommand(fromCategoryID: nil, toCategoryID: "groceries", amount: 0, kind: .transferAvailable)
            let drafts = try budget.moveMoneyMessages(commands: [none], month: "2026-07", db: db, builder: &builder)
            return UserActionPlan(drafts: drafts, descriptor: nil, outcome: drafts)
        }.outcome
        #expect(zero.contains { $0.column == "amount" })
    }
}
