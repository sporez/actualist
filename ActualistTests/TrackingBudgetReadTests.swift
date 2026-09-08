import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct TrackingBudgetReadTests {
    private func fixture(_ sql: String = "") throws -> URL {
        let url = try TrackingBudgetDatabaseContractTests().makeTrackingContractFixture()
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in try db.execute(sql: sql) }
        return url
    }

    @Test func hiddenTotalsUseFirstIncomeGroupAndPreserveReadableRows() async throws {
        let url = try fixture("""
            INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 0);
            INSERT INTO category_groups VALUES ('extra-income', 'Extra Income', 1, 0, 0, 2);
            INSERT INTO category_groups VALUES ('hidden-group', 'Hidden', 0, 1, 0, 3);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income', 1, 0, 0, 1);
            INSERT INTO categories VALUES ('hidden-income', 'Hidden Income', 'income', 1, 1, 0, 2);
            INSERT INTO categories VALUES ('other-income', 'Other Income', 'extra-income', 1, 0, 0, 3);
            INSERT INTO categories VALUES ('hidden-child', 'Hidden Child', 'group', 0, 1, 0, 4);
            INSERT INTO categories VALUES ('hidden-expense', 'Hidden Expense', 'hidden-group', 0, 0, 0, 5);
            INSERT INTO reflect_budgets VALUES ('202607-salary', 202607, 'salary', 1500, 0);
            INSERT INTO reflect_budgets VALUES ('202607-hidden-income', 202607, 'hidden-income', 9000, 0);
            INSERT INTO reflect_budgets VALUES ('202607-other-income', 202607, 'other-income', 8000, 0);
            INSERT INTO reflect_budgets VALUES ('202607-hidden-child', 202607, 'hidden-child', 7000, 0);
            INSERT INTO reflect_budgets VALUES ('202607-hidden-expense', 202607, 'hidden-expense', 6000, 0);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone) VALUES
              ('salary', 'checking', 20260701, 1200, 'salary', 0),
              ('expense', 'checking', 20260702, -300, 'groceries', 0),
              ('hidden-income', 'checking', 20260702, 9000, 'hidden-income', 0),
              ('other-income', 'checking', 20260702, 8000, 'other-income', 0),
              ('hidden-child', 'checking', 20260702, -7000, 'hidden-child', 0),
              ('hidden-expense', 'checking', 20260702, -6000, 'hidden-expense', 0);
            """)
        let database = try BudgetDatabase(databaseURL: url)
        let month = try await database.fetchBudgetMonth(month: "2026-07")
        #expect(month.totalBudgeted == 500)
        #expect(month.totalSpent == -300)
        #expect(month.totalIncome == 1200)
        #expect(month.totalBalance == 200)
        #expect(month.categoryGroups.flatMap(\.categories).count == 6)
        #expect(month.trackingSummary?.plannedSavings == 1000)
        #expect(month.trackingSummary?.actualSavings == 900)
        #expect(month.toBudget == 0)
        #expect(month.forNextMonth == 0)
        #expect(try await database.trackingContractPlannedSavings(month: "2026-07") == 1000)
        let encoded = try JSONEncoder().encode(month)
        #expect(try JSONDecoder().decode(BudgetMonth.self, from: encoded) == month)
    }

    @Test func missingInterveningMonthStopsRolloverAndPastEditsRecompute() async throws {
        let url = try fixture("""
            UPDATE reflect_budgets SET carryover = 1 WHERE month = 202607;
            INSERT INTO reflect_budgets VALUES ('202609-groceries', 202609, 'groceries', 200, 1);
            INSERT INTO reflect_budgets VALUES ('202610-groceries', 202610, 'groceries', 100, 0);
            """)
        let database = try BudgetDatabase(databaseURL: url)
        #expect(try await database.fetchBudgetMonth(month: "2026-08").totalBalance == 500)
        #expect(try await database.fetchBudgetMonth(month: "2026-09").totalBalance == 200)
        #expect(try await database.fetchBudgetMonth(month: "2026-10").totalBalance == 300)
        let change = ActualSyncDecodedMessage(timestamp: "2026-09-01T00:00:00.000Z-0000-0000000000000001",
            dataset: "reflect_budgets", row: "202609-groceries", column: "amount", serializedValue: "N:-600")
        _ = try await database.applyRemoteSyncMessages([change])
        #expect(try await database.fetchBudgetMonth(month: "2026-10").totalBalance == -500)
        #expect(try await database.trackingContractTemplateCarry(month: 202610) == -600)
        let reopened = try BudgetDatabase(databaseURL: url)
        #expect(try await reopened.fetchBudgetMonth(month: "2026-10").totalBalance == -500)
    }

    @Test func envelopeTotalsAndMissingMetadataRemainEnvelope() async throws {
        let url = try fixture("""
            DELETE FROM preferences;
            INSERT INTO zero_budgets VALUES (202608, 'groceries', 100, 0);
            UPDATE categories SET hidden = 1;
            UPDATE category_groups SET hidden = 1;
            """)
        let database = try BudgetDatabase(databaseURL: url)
        let month = try await database.fetchBudgetMonth(month: "2026-08")
        #expect(month.totalBalance == 600)
        #expect(month.totalBudgeted == 100)
        #expect(month.toBudget == -600)
        #expect(month.trackingSummary == nil)
        #expect(try await database.fetchAvailableMonths() == ["2026-07", "2026-08"])
    }

    @Test func currentFlagAffectsFollowingMonthAcrossYearBoundary() async throws {
        let url = try fixture("""
            DELETE FROM reflect_budgets;
            INSERT INTO reflect_budgets VALUES ('202612-groceries', 202612, 'groceries', -500, 1);
            INSERT INTO reflect_budgets VALUES ('202701-groceries', 202701, 'groceries', 100, 0);
            """)
        let database = try BudgetDatabase(databaseURL: url)
        #expect(try await database.fetchBudgetMonth(month: "2027-01").totalBalance == -400)
        #expect(try await database.fetchBudgetMonth(month: "2027-02").totalBalance == 0)
    }

    @Test func splitMappingRefundAndOffBudgetActivityUseSharedInlineQuery() async throws {
        let url = try fixture("""
            INSERT INTO accounts VALUES ('off', 'Off Budget', 1, 0, 0, 2);
            INSERT INTO category_mapping VALUES ('retired', 'groceries');
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent) VALUES
              ('parent', 'checking', 20260701, -400, NULL, 0, NULL, 1),
              ('child-a', 'checking', 20260701, -250, 'retired', 0, 'parent', 0),
              ('child-b', 'checking', 20260701, -150, 'groceries', 0, 'parent', 0),
              ('refund', 'checking', 20260702, 50, 'groceries', 0, NULL, 0),
              ('off', 'off', 20260702, -9000, 'groceries', 0, NULL, 0),
              ('deleted', 'checking', 20260702, -8000, 'groceries', 1, NULL, 0),
              ('uncategorized', 'checking', 20260702, -7000, NULL, 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: url)
        let month = try await database.fetchBudgetMonth(month: "2026-07")
        #expect(month.totalSpent == -350)
        #expect(month.totalBalance == 150)
        #expect(month.trackingSummary?.actualSavings == -350)
    }

    @Test func discoveryNormalizesActiveMonthsAndIgnoresInactiveSentinels() async throws {
        let url = try fixture("""
            INSERT INTO zero_budgets VALUES (203101, 'groceries', 1, 0);
            INSERT INTO reflect_budgets VALUES ('august', '2026-8', 'groceries', 0, 0);
            INSERT INTO reflect_budgets VALUES ('invalid', '2026-13', 'groceries', 0, 0);
            INSERT INTO transactions (id, date, tombstone) VALUES ('live', 20240229, 0), ('dead', 20400101, 1);
            """)
        let database = try BudgetDatabase(databaseURL: url)
        #expect(try await database.fetchAvailableMonths() == ["2024-02", "2026-07", "2026-08", "2029-12"])
        let reopened = try BudgetDatabase(databaseURL: url)
        #expect(try await reopened.fetchAvailableMonths() == ["2024-02", "2026-07", "2026-08", "2029-12"])
    }

    @Test func trackingAmountsRemainIntegerUnitsForEveryCurrency() async throws {
        for code in ["USD", "JPY", ""] {
            let url = try fixture()
            let queue = try DatabaseQueue(path: url.path)
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO preferences VALUES ('defaultCurrencyCode', ?)", arguments: [code])
            }
            let database = try BudgetDatabase(databaseURL: url)
            let month = try await database.fetchBudgetMonth(month: "2026-07")
            let currency = try await database.fetchBudgetCurrency()
            #expect(month.totalBudgeted == 500)
            #expect(month.trackingSummary?.plannedSavings == -500)
            #expect(currency.displayUnits(fromMinorUnits: 500) == (code == "JPY" ? 500 : 5))
        }
    }

    @Test func emptyAndUnknownMetadataUseExplicitReadResults() async throws {
        let url = try fixture("""
            DELETE FROM reflect_budgets;
            DELETE FROM zero_budgets;
            UPDATE preferences SET value = 'future-mode' WHERE id = 'budgetType';
            """)
        let database = try BudgetDatabase(databaseURL: url)
        #expect(try await database.fetchAvailableMonths().isEmpty)
        let month = try await database.fetchBudgetMonth(month: "2026-07")
        #expect(month.trackingSummary == nil)
        #expect(month.totalBalance == 0)
        await #expect(throws: (any Error).self) {
            try await database.fetchBudgetMonth(month: "2026-13")
        }
    }

    @Test func financialSnapshotCouplesCurrencyModeAndCurrentSelectedMonths() async throws {
        let url = try fixture("INSERT INTO preferences VALUES ('defaultCurrencyCode', 'JPY');")
        let database = try BudgetDatabase(databaseURL: url)
        let now = try #require(Calendar(identifier: .gregorian).date(from:
            DateComponents(year: 2026, month: 9, day: 8, hour: 12)))
        let snapshot = try await database.fetchBudgetSnapshot(month: "2026-08", now: now)
        #expect(snapshot.month.trackingSummary != nil)
        #expect(snapshot.currency.code == "JPY")
        #expect(snapshot.availableMonths == ["2026-07", "2026-08", "2026-09", "2029-12"])
    }

    @Test func unreadableModeMetadataThrowsRatherThanPublishingEnvelope() async throws {
        let url = try fixture("DROP TABLE preferences; CREATE TABLE preferences (id TEXT PRIMARY KEY);")
        let database = try BudgetDatabase(databaseURL: url)
        await #expect(throws: LocalFirstError.invalidDownloadedBudget) {
            try await database.fetchBudgetSnapshot(month: "2026-07")
        }
    }

    @Test func summariesChoosePlannedOrActualWithoutChangingTemplateAvailability() throws {
        for planned in [-100, 0, 100] {
            for actual in [-200, 0, 200] {
                let summary = TrackingBudgetSummary(budgetedIncome: 500 + planned,
                    budgetedExpenses: 500, receivedIncome: 300 + actual, expenseActivity: -300,
                    plannedSavings: planned, actualSavings: actual)
                #expect(summary.headline(month: "2026-12", currentMonth: "2026-12").amount == planned)
                #expect(summary.headline(month: "2027-01", currentMonth: "2026-12").kind == .projectedSavings)
                let closed = summary.headline(month: "2026-12", currentMonth: "2027-01")
                #expect(closed.amount == actual)
                #expect(closed.kind == (actual < 0 ? .overspent : .saved))
                #expect(closed.income == 300 + actual)
                #expect(closed.expenses == 300)
                #expect(summary.plannedSavings == planned)
            }
        }
    }

    @Test func unsafeTrackingArithmeticThrowsInsteadOfWrapping() throws {
        #expect(throws: LocalFirstError.numericValueOutOfRange) {
            try BudgetFinancialCalculation.sum([1 << 51], table: .tracking)
        }
        #expect(throws: LocalFirstError.numericValueOutOfRange) {
            try BudgetFinancialCalculation.sum([Int.max, 1], table: .envelope)
        }
        #expect(throws: LocalFirstError.numericValueOutOfRange) {
            try BudgetFinancialCalculation.category(table: .tracking, isIncome: true,
                budgeted: 0, activity: Int.min, carryover: false, previous: BudgetCategoryValue())
        }
    }
}

extension BudgetDatabase {
    func trackingContractPlannedSavings(month: String) throws -> Int {
        try queue.read { db in try trackingTotalSaved(month: month, db: db) }
    }

    func trackingContractTemplateCarry(month: Int) throws -> Int {
        try queue.read { db in
            try templateFromLastMonth(categoryID: "groceries", monthValue: month,
                isIncome: false, isTrackingBudget: true, db: db)
        }
    }
}
