import Foundation
import GRDB
import Testing
@testable import Actualist

/// Envelope month values per loot-core `budget/envelope.ts` (Y13 in the audit designs).
@MainActor
struct EnvelopeMonthCarryInTests {
    private let fixtures = LocalFirstActualStoreTests()

    /// July: income 100000, groceries budgeted 50000 (spent 12345, carryover on),
    /// dining unbudgeted (spent 2000, no carryover), 25000 held for next month.
    private static let sql = """
        CREATE TABLE zero_budget_months (id TEXT PRIMARY KEY, buffered INTEGER);
        INSERT INTO zero_budget_months VALUES ('2026-07', 25000);
        INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 2);
        INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
            VALUES ('salary', 'Salary', 'income', 1, 0, 0, 1);
        INSERT INTO category_mapping VALUES ('salary', 'salary');
        INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent)
            VALUES ('pay', 'checking', 20260701, 100000, 'salary', 0, NULL, 0);
        INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent)
            VALUES ('meal', 'checking', 20260705, -2000, 'dining', 0, NULL, 0);
        """

    /// The store fixture already defines Dining; the plain database fixture does not.
    private static let diningSQL = """
        INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
            VALUES ('dining', 'Dining', 'group', 0, 0, 0, 2);
        INSERT INTO category_mapping VALUES ('dining', 'dining');
        """

    private func database() throws -> BudgetDatabase {
        try BudgetDatabase(databaseURL: fixtures.makeSQLiteFixture(extraSQL: Self.diningSQL + "\n" + Self.sql))
    }

    private func carryIn(_ database: BudgetDatabase, month: String) async throws -> BudgetDatabase.EnvelopeCarryIn {
        try await database.envelopeCarryInForTesting(month: month)
    }

    @Test func firstMonthHasNoCarryIn() async throws {
        let july = try await database().fetchBudgetMonth(month: "2026-07")
        #expect(july.fromLastMonth == 0)
        #expect(july.forNextMonth == 25_000)
        #expect(july.incomeAvailable == 100_000)
        #expect(july.toBudget == 25_000)
    }

    @Test func nextMonthReturnsPreviousToBudgetPlusHoldAndSubtractsOverspending() async throws {
        let database = try database()
        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let august = try await database.fetchBudgetMonth(month: "2026-08")

        // from-last-month = previous to-budget + previous hold: the hold returns.
        #expect(august.fromLastMonth == july.toBudget + july.forNextMonth)
        #expect(august.fromLastMonth == 50_000)
        // available-funds = total-income + from-last-month; it is not To Budget.
        #expect(august.incomeAvailable == august.totalIncome + august.fromLastMonth)
        #expect(august.incomeAvailable != august.toBudget)
        #expect(august.toBudget == 48_000)
    }

    @Test func toBudgetIdentityHoldsForEveryMonth() async throws {
        let database = try database()
        for month in ["2026-07", "2026-08", "2026-09"] {
            let loaded = try await database.fetchBudgetMonth(month: month)
            let carry = try await carryIn(database, month: month)
            #expect(carry.fromLastMonth == loaded.fromLastMonth, "\(month)")
            // to-budget = available-funds + last-month-overspent - total-budgeted - buffered
            let expected = loaded.incomeAvailable + carry.lastMonthOverspent
                - loaded.totalBudgeted - loaded.forNextMonth
            #expect(loaded.toBudget == expected, "\(month)")
        }
        #expect(try await carryIn(database, month: "2026-08").lastMonthOverspent == -2_000)
    }

    @Test func shortcutsSummaryReportsFromLastMonthAndAvailableFunds() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.sql)
        let july = try await bundle.store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let august = try await bundle.store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-08")
        let summary = BudgetSummaryEntity.make(from: august, currentMonth: "2026-08")

        let carried = july.month.toBudget + july.month.forNextMonth
        #expect(carried != 0)
        #expect(try ShortcutMoney.minorUnits(from: #require(summary.fromLastMonth)) == carried)
        #expect(
            try ShortcutMoney.minorUnits(from: #require(summary.incomeAvailable))
                == august.month.totalIncome + carried
        )
        #expect(try ShortcutMoney.minorUnits(from: #require(summary.readyToAssign)) == august.month.toBudget)
    }
}

extension BudgetDatabase {
    func envelopeCarryInForTesting(month: String) throws -> EnvelopeCarryIn {
        try queue.read { db in
            let values = try categoryValuesWithPrevious(through: month, db: db)
            let groups = try fetchCategoryGroups(categoryValues: values.current, db: db)
            return try envelopeCarryIn(
                month: month, groups: groups, previousValues: values.previous, db: db
            )
        }
    }
}
