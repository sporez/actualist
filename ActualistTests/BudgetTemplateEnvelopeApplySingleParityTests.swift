import Foundation
import GRDB
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    enum EnvelopeApplySingleCase: String, CaseIterable, Sendable {
        case mode
        case simple
        case copy
        case periodic
        case by
        case monthlyLimit
        case dailyLimit
        case weeklyLimit
        case refill
        case average
        case adjustedAverage
        case currentIncomePercent
        case previousIncomePercent
        case availablePercent
        case spend
        case monthlySchedule
        case annualSchedule
        case priorityOne
        case remainderCapped
        case remainderOpen
        case goalOnly
        case mixedGoal
        case orphanGoal

        var categoryID: String {
            switch self {
            case .monthlyLimit: "monthly-limit"
            case .dailyLimit: "daily-limit"
            case .weeklyLimit: "weekly-limit"
            case .adjustedAverage: "adjusted-average"
            case .currentIncomePercent: "current-income-percent"
            case .previousIncomePercent: "previous-income-percent"
            case .availablePercent: "available-percent"
            case .monthlySchedule: "monthly-schedule"
            case .annualSchedule: "annual-schedule"
            case .priorityOne: "priority-one"
            case .remainderCapped: "remainder-capped"
            case .remainderOpen: "remainder-open"
            case .goalOnly: "goal-only"
            case .mixedGoal: "mixed-goal"
            case .orphanGoal: "orphan-goal"
            default: rawValue
            }
        }

        var expected: BudgetTemplateApplySingleStoredRow {
            switch self {
            case .mode: BudgetTemplateApplySingleStoredRow(amount: 9_900, goal: 9_900)
            case .simple: BudgetTemplateApplySingleStoredRow(amount: 10_000, goal: 10_000)
            case .copy: BudgetTemplateApplySingleStoredRow(amount: 7_300, goal: 7_300)
            case .periodic: BudgetTemplateApplySingleStoredRow(amount: 5_000, goal: 5_000)
            case .by: BudgetTemplateApplySingleStoredRow(amount: 20_000, goal: 20_000)
            case .monthlyLimit: BudgetTemplateApplySingleStoredRow(amount: 6_000, goal: 6_000)
            case .dailyLimit: BudgetTemplateApplySingleStoredRow(amount: 9_300, goal: 9_300)
            case .weeklyLimit: BudgetTemplateApplySingleStoredRow(amount: 10_000, goal: 10_000)
            case .refill: BudgetTemplateApplySingleStoredRow(amount: 6_000, goal: 6_000)
            case .average: BudgetTemplateApplySingleStoredRow(amount: 9_000, goal: 9_000)
            case .adjustedAverage: BudgetTemplateApplySingleStoredRow(amount: 11_000, goal: 11_000)
            case .currentIncomePercent: BudgetTemplateApplySingleStoredRow(amount: 100_000, goal: 100_000)
            case .previousIncomePercent: BudgetTemplateApplySingleStoredRow(amount: 25_000, goal: 25_000)
            case .availablePercent: BudgetTemplateApplySingleStoredRow(amount: 49_840, goal: 49_840)
            case .spend: BudgetTemplateApplySingleStoredRow(amount: 30_000, goal: 30_000)
            case .monthlySchedule: BudgetTemplateApplySingleStoredRow(amount: 12_500, goal: 12_500)
            case .annualSchedule: BudgetTemplateApplySingleStoredRow(amount: 17_143, goal: 17_143)
            case .priorityOne: BudgetTemplateApplySingleStoredRow(amount: 11_100, goal: 11_100)
            case .remainderCapped: BudgetTemplateApplySingleStoredRow(amount: 50_000)
            case .remainderOpen: BudgetTemplateApplySingleStoredRow(amount: 996_800)
            case .goalOnly: BudgetTemplateApplySingleStoredRow(amount: 2_500, goal: 50_000, longGoal: 1)
            case .mixedGoal: BudgetTemplateApplySingleStoredRow(amount: 8_000, goal: 100_000, longGoal: 1)
            case .orphanGoal: BudgetTemplateApplySingleStoredRow(amount: 0)
            }
        }

        var expectedJPYSingle: BudgetTemplateApplySingleStoredRow {
            switch self {
            case .mode: BudgetTemplateApplySingleStoredRow(amount: 99, goal: 99)
            case .simple: BudgetTemplateApplySingleStoredRow(amount: 100, goal: 100)
            case .copy: BudgetTemplateApplySingleStoredRow(amount: 73, goal: 73)
            case .periodic: BudgetTemplateApplySingleStoredRow(amount: 50, goal: 50)
            case .by: BudgetTemplateApplySingleStoredRow(amount: 200, goal: 200)
            case .monthlyLimit: BudgetTemplateApplySingleStoredRow(amount: 60, goal: 60)
            case .dailyLimit: BudgetTemplateApplySingleStoredRow(amount: 93, goal: 93)
            case .weeklyLimit: BudgetTemplateApplySingleStoredRow(amount: 100, goal: 100)
            case .refill: BudgetTemplateApplySingleStoredRow(amount: 60, goal: 60)
            case .average: BudgetTemplateApplySingleStoredRow(amount: 90, goal: 90)
            case .adjustedAverage: BudgetTemplateApplySingleStoredRow(amount: 110, goal: 110)
            case .currentIncomePercent: BudgetTemplateApplySingleStoredRow(amount: 1_000, goal: 1_000)
            case .previousIncomePercent: BudgetTemplateApplySingleStoredRow(amount: 250, goal: 250)
            case .availablePercent: BudgetTemplateApplySingleStoredRow(amount: 498, goal: 498)
            case .spend: BudgetTemplateApplySingleStoredRow(amount: 300, goal: 300)
            case .monthlySchedule: BudgetTemplateApplySingleStoredRow(amount: 125, goal: 125)
            case .annualSchedule: BudgetTemplateApplySingleStoredRow(amount: 171, goal: 171)
            case .priorityOne: BudgetTemplateApplySingleStoredRow(amount: 111, goal: 111)
            case .remainderCapped: BudgetTemplateApplySingleStoredRow(amount: 500)
            case .remainderOpen: BudgetTemplateApplySingleStoredRow(amount: 9_968)
            case .goalOnly: BudgetTemplateApplySingleStoredRow(amount: 25, goal: 500, longGoal: 1)
            case .mixedGoal: BudgetTemplateApplySingleStoredRow(amount: 80, goal: 1_000, longGoal: 1)
            case .orphanGoal: BudgetTemplateApplySingleStoredRow(amount: 0)
            }
        }

        var expectedJPYWhole: BudgetTemplateApplySingleStoredRow {
            switch self {
            case .availablePercent:
                BudgetTemplateApplySingleStoredRow(amount: 499, goal: 499)
            case .remainderOpen:
                BudgetTemplateApplySingleStoredRow(amount: 5_904)
            default:
                expectedJPYSingle
            }
        }
    }

    @Test(arguments: EnvelopeApplySingleCase.allCases)
    func budgetTemplateEnvelopeApplySingleMatchesActual2681(
        testCase: EnvelopeApplySingleCase
    ) async throws {
        let fixtureURL = try makeEnvelopeApplySingleFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let monthBefore = try await database.fetchBudgetMonth(month: "2026-07")
        #expect(monthBefore.toBudget == 996_800)
        let baseline = try budgetTemplateApplySingleRows(
            table: "zero_budgets",
            month: 202607,
            at: fixtureURL
        )
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.budgetTemplateMessages(
            command: .category(testCase.categoryID),
            month: "2026-07",
            currentMonth: "2026-08",
            builder: &builder
        )

        #expect(!messages.isEmpty)
        #expect(!messages.contains { $0.dataset == "reflect_budgets" })
        _ = try await database.applyLocalSyncMessages(messages)

        let after = try budgetTemplateApplySingleRows(
            table: "zero_budgets",
            month: 202607,
            at: fixtureURL
        )
        #expect(after[testCase.categoryID] == testCase.expected)
        for (categoryID, row) in baseline where categoryID != testCase.categoryID {
            #expect(after[categoryID] == row)
        }
        #expect(try envelopeReflectRowCount(at: fixtureURL) == 0)
    }

    @Test(arguments: EnvelopeApplySingleCase.allCases)
    func budgetTemplateJPYEnvelopeApplySingleMatchesActual2681(
        testCase: EnvelopeApplySingleCase
    ) async throws {
        let fixtureURL = try makeJPYEnvelopeFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        #expect(try await database.fetchBudgetMonth(month: "2026-07").toBudget == 9_968)
        let baseline = try budgetTemplateApplySingleRows(
            table: "zero_budgets",
            month: 202607,
            at: fixtureURL
        )
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category(testCase.categoryID),
            month: "2026-07",
            currentMonth: "2026-08",
            builder: &builder
        )
        #expect(!messages.contains { $0.dataset == "reflect_budgets" })
        _ = try await database.applyLocalSyncMessages(messages)
        let after = try budgetTemplateApplySingleRows(
            table: "zero_budgets",
            month: 202607,
            at: fixtureURL
        )
        #expect(after[testCase.categoryID] == testCase.expectedJPYSingle)
        for (categoryID, row) in baseline where categoryID != testCase.categoryID {
            #expect(after[categoryID] == row)
        }
        #expect(try envelopeReflectRowCount(at: fixtureURL) == 0)
    }

    @Test func budgetTemplateJPYEnvelopeOverwriteMatchesActual2681() async throws {
        let fixtureURL = try makeJPYEnvelopeFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .overwrite,
            month: "2026-07",
            currentMonth: "2026-08",
            builder: &builder
        )
        #expect(!messages.contains { $0.dataset == "reflect_budgets" })
        _ = try await database.applyLocalSyncMessages(messages)
        let after = try budgetTemplateApplySingleRows(
            table: "zero_budgets",
            month: 202607,
            at: fixtureURL
        )
        for testCase in EnvelopeApplySingleCase.allCases {
            #expect(after[testCase.categoryID] == testCase.expectedJPYWhole)
        }
        #expect(try envelopeReflectRowCount(at: fixtureURL) == 0)
    }

    private func makeJPYEnvelopeFixture() throws -> URL {
        let fixtureURL = try makeEnvelopeApplySingleFixture()
        let queue = try DatabaseQueue(path: fixtureURL.path)
        try queue.write { db in
            try db.execute(sql: """
                UPDATE preferences SET value = 'JPY' WHERE id = 'defaultCurrencyCode';
                UPDATE zero_budgets
                SET amount = CAST(ROUND(amount / 100.0) AS INTEGER),
                    goal = CASE WHEN goal IS NULL THEN NULL ELSE CAST(ROUND(goal / 100.0) AS INTEGER) END;
                UPDATE transactions SET amount = CAST(ROUND(amount / 100.0) AS INTEGER);
                UPDATE rules
                SET conditions = REPLACE(REPLACE(conditions, '-12500', '-125'), '-120000', '-1200');
                """)
        }
        return fixtureURL
    }

    private func makeEnvelopeApplySingleFixture() throws -> URL {
        try makeSQLiteFixture(extraSQL: """
            DELETE FROM transactions;
            DELETE FROM zero_budgets;
            UPDATE category_groups SET hidden = 1 WHERE id = 'group';
            UPDATE categories SET hidden = 1 WHERE id = 'groceries';
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE zero_budgets ADD COLUMN goal INTEGER;
            ALTER TABLE zero_budgets ADD COLUMN long_goal INTEGER;
            CREATE TABLE reflect_budgets (
                id TEXT PRIMARY KEY, month INTEGER, category TEXT, amount INTEGER,
                carryover INTEGER, goal INTEGER, long_goal INTEGER
            );
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('budgetType', 'envelope');
            INSERT INTO preferences VALUES ('defaultCurrencyCode', 'USD');
            INSERT INTO preferences VALUES ('hideFraction', 'false');

            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 0);
            INSERT INTO category_groups VALUES ('fixed-group', 'Fixed', 0, 0, 0, 1);
            INSERT INTO category_groups VALUES ('limits-group', 'Limits', 0, 0, 0, 2);
            INSERT INTO category_groups VALUES ('history-group', 'History', 0, 0, 0, 3);
            INSERT INTO category_groups VALUES ('schedule-group', 'Schedules', 0, 0, 0, 4);
            INSERT INTO category_groups VALUES ('allocation-group', 'Allocation', 0, 0, 0, 5);
            INSERT INTO category_groups VALUES ('goal-group', 'Goals', 0, 0, 0, 6);
            INSERT INTO category_groups VALUES ('sink-group', 'Fixture Inputs', 0, 1, 0, 7);

            INSERT INTO categories VALUES ('income', 'Income', 'income-group', 1, 0, 0, 0, NULL);
            INSERT INTO categories VALUES ('mode', 'Mode', 'fixed-group', 0, 0, 0, 0,
                '[{"directive":"template","type":"simple","monthly":99,"limit":null,"priority":0}]');
            INSERT INTO categories VALUES ('simple', 'Simple', 'fixed-group', 0, 0, 0, 1,
                '[{"directive":"template","type":"simple","monthly":100,"limit":null,"priority":0}]');
            INSERT INTO categories VALUES ('copy', 'Copy', 'fixed-group', 0, 0, 0, 2,
                '[{"directive":"template","type":"copy","lookBack":1,"priority":0}]');
            INSERT INTO categories VALUES ('periodic', 'Periodic', 'fixed-group', 0, 0, 0, 3,
                '[{"directive":"template","type":"periodic","amount":10,"period":{"amount":1,"period":"week"},"starting":"2026-07-01","limit":null,"priority":0}]');
            INSERT INTO categories VALUES ('by', 'By', 'fixed-group', 0, 0, 0, 4,
                '[{"directive":"template","type":"by","amount":600,"month":"2026-09","annual":false,"repeat":null,"priority":0}]');
            INSERT INTO categories VALUES ('monthly-limit', 'Monthly Limit', 'limits-group', 0, 0, 0, 0,
                '[{"directive":"template","type":"simple","monthly":200,"limit":{"amount":100,"period":"monthly","hold":true},"priority":0}]');
            INSERT INTO categories VALUES ('daily-limit', 'Daily Limit', 'limits-group', 0, 0, 0, 1,
                '[{"directive":"template","type":"simple","monthly":200,"limit":{"amount":3,"period":"daily","hold":true},"priority":0}]');
            INSERT INTO categories VALUES ('weekly-limit', 'Weekly Limit', 'limits-group', 0, 0, 0, 2,
                '[{"directive":"template","type":"simple","monthly":200,"limit":{"amount":20,"period":"weekly","start":"2026-07-01","hold":true},"priority":0}]');
            INSERT INTO categories VALUES ('refill', 'Refill', 'limits-group', 0, 0, 0, 3,
                '[{"directive":"template","type":"limit","amount":100,"period":"monthly","hold":true,"priority":null},{"directive":"template","type":"refill","priority":0}]');
            INSERT INTO categories VALUES ('average', 'Average', 'history-group', 0, 0, 0, 0,
                '[{"directive":"template","type":"average","numMonths":3,"priority":0}]');
            INSERT INTO categories VALUES ('adjusted-average', 'Adjusted Average', 'history-group', 0, 0, 0, 1,
                '[{"directive":"template","type":"average","numMonths":3,"adjustment":10,"adjustmentType":"percent","priority":0}]');
            INSERT INTO categories VALUES ('current-income-percent', 'Current Income', 'history-group', 0, 0, 0, 2,
                '[{"directive":"template","type":"percentage","percent":10,"category":"all income","previous":false,"priority":0}]');
            INSERT INTO categories VALUES ('previous-income-percent', 'Previous Income', 'history-group', 0, 0, 0, 3,
                '[{"directive":"template","type":"percentage","percent":5,"category":"income","previous":true,"priority":0}]');
            INSERT INTO categories VALUES ('available-percent', 'Available', 'history-group', 0, 0, 0, 4,
                '[{"directive":"template","type":"percentage","percent":5,"category":"available funds","previous":false,"priority":0}]');
            INSERT INTO categories VALUES ('spend', 'Spend', 'schedule-group', 0, 0, 0, 0,
                '[{"directive":"template","type":"spend","amount":900,"from":"2026-07","month":"2026-09","annual":false,"repeat":null,"priority":0}]');
            INSERT INTO categories VALUES ('monthly-schedule', 'Monthly Schedule', 'schedule-group', 0, 0, 0, 1,
                '[{"directive":"template","type":"schedule","name":"Sandbox Monthly Bill","scheduleId":"monthly-schedule-id","full":false,"priority":0}]');
            INSERT INTO categories VALUES ('annual-schedule', 'Annual Schedule', 'schedule-group', 0, 0, 0, 2,
                '[{"directive":"template","type":"schedule","name":"Sandbox Annual Bill","scheduleId":"annual-schedule-id","full":false,"priority":0}]');
            INSERT INTO categories VALUES ('priority-one', 'Priority', 'allocation-group', 0, 0, 0, 0,
                '[{"directive":"template","type":"simple","monthly":111,"limit":null,"priority":1}]');
            INSERT INTO categories VALUES ('remainder-capped', 'Remainder Capped', 'allocation-group', 0, 0, 0, 1,
                '[{"directive":"template","type":"remainder","weight":1,"limit":{"amount":500,"period":"monthly","hold":true},"priority":null}]');
            INSERT INTO categories VALUES ('remainder-open', 'Remainder Open', 'allocation-group', 0, 0, 0, 2,
                '[{"directive":"template","type":"remainder","weight":2,"limit":null,"priority":null}]');
            INSERT INTO categories VALUES ('goal-only', 'Goal Only', 'goal-group', 0, 0, 0, 0,
                '[{"directive":"goal","type":"goal","amount":500,"priority":0}]');
            INSERT INTO categories VALUES ('mixed-goal', 'Mixed Goal', 'goal-group', 0, 0, 0, 1,
                '[{"directive":"template","type":"simple","monthly":80,"limit":null,"priority":0},{"directive":"goal","type":"goal","amount":1000,"priority":0}]');
            INSERT INTO categories VALUES ('orphan-goal', 'Orphan Goal', 'goal-group', 0, 0, 0, 2, NULL);
            INSERT INTO categories VALUES ('sink', 'Sink', 'sink-group', 0, 0, 0, 0, NULL);

            INSERT INTO zero_budgets (month, category, amount, carryover, goal, long_goal)
            SELECT 202607, id, 0, 0, NULL, NULL FROM categories WHERE goal_def IS NOT NULL;
            INSERT INTO zero_budgets VALUES (202607, 'orphan-goal', 0, 0, 33300, NULL);
            UPDATE zero_budgets SET amount = 700 WHERE month = 202607 AND category = 'mode';
            UPDATE zero_budgets SET amount = 2500 WHERE month = 202607 AND category = 'goal-only';
            INSERT INTO zero_budgets VALUES (202606, 'copy', 7300, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202606, 'monthly-limit', 4000, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202606, 'refill', 4000, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202604, 'average', 6000, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202605, 'average', 9000, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202606, 'average', 12000, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202604, 'adjusted-average', 10000, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202605, 'adjusted-average', 10000, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202606, 'adjusted-average', 10000, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202604, 'sink', 484000, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202605, 'sink', 481000, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202606, 'sink', 462700, 0, NULL, NULL);

            INSERT INTO transactions VALUES ('income-apr', 'checking', 20260401, 500000, 'income', 0, NULL, 0);
            INSERT INTO transactions VALUES ('income-may', 'checking', 20260501, 500000, 'income', 0, NULL, 0);
            INSERT INTO transactions VALUES ('income-jun', 'checking', 20260601, 500000, 'income', 0, NULL, 0);
            INSERT INTO transactions VALUES ('income-jul', 'checking', 20260701, 1000000, 'income', 0, NULL, 0);
            INSERT INTO transactions VALUES ('average-apr', 'checking', 20260415, -6000, 'average', 0, NULL, 0);
            INSERT INTO transactions VALUES ('average-may', 'checking', 20260515, -9000, 'average', 0, NULL, 0);
            INSERT INTO transactions VALUES ('average-jun', 'checking', 20260615, -12000, 'average', 0, NULL, 0);
            INSERT INTO transactions VALUES ('adjusted-apr', 'checking', 20260415, -10000, 'adjusted-average', 0, NULL, 0);
            INSERT INTO transactions VALUES ('adjusted-may', 'checking', 20260515, -10000, 'adjusted-average', 0, NULL, 0);
            INSERT INTO transactions VALUES ('adjusted-jun', 'checking', 20260615, -10000, 'adjusted-average', 0, NULL, 0);

            CREATE TABLE rules (id TEXT PRIMARY KEY, conditions TEXT, actions TEXT, tombstone INTEGER);
            CREATE TABLE schedules (id TEXT PRIMARY KEY, name TEXT, rule TEXT, completed INTEGER, tombstone INTEGER);
            INSERT INTO rules VALUES ('monthly-rule',
                '[{"op":"is","field":"amount","value":-12500},{"op":"is","field":"date","value":{"start":"2026-07-15","frequency":"monthly","interval":1}}]',
                '[{"op":"link-schedule","value":"monthly-schedule-id"}]', 0);
            INSERT INTO rules VALUES ('annual-rule',
                '[{"op":"is","field":"amount","value":-120000},{"op":"is","field":"date","value":{"start":"2027-01-15","frequency":"yearly","interval":1}}]',
                '[{"op":"link-schedule","value":"annual-schedule-id"}]', 0);
            INSERT INTO schedules VALUES ('monthly-schedule-id', 'Sandbox Monthly Bill', 'monthly-rule', 0, 0);
            INSERT INTO schedules VALUES ('annual-schedule-id', 'Sandbox Annual Bill', 'annual-rule', 0, 0);
            """)
    }

    private func envelopeReflectRowCount(at databaseURL: URL) throws -> Int {
        let queue = try DatabaseQueue(path: databaseURL.path)
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reflect_budgets") ?? 0
        }
    }
}
