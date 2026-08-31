import Foundation
import GRDB
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    enum TrackingApplySingleCase: String, CaseIterable, Sendable {
        case mode
        case fixed
        case income
        case priorityAfterIncome
        case noCarryRefill
        case carryRefill
        case copy
        case availablePercent
        case remainderCapped
        case remainderOpen
        case goalOnly
        case mixedGoal
        case orphanGoal

        var categoryID: String {
            switch self {
            case .priorityAfterIncome: "priority"
            case .noCarryRefill: "no-carry"
            case .carryRefill: "carry"
            case .availablePercent: "available"
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
            case .mode:
                BudgetTemplateApplySingleStoredRow(amount: 9_900, goal: 9_900)
            case .fixed:
                BudgetTemplateApplySingleStoredRow(amount: 10_000, goal: 10_000)
            case .income:
                BudgetTemplateApplySingleStoredRow(amount: 100_000, goal: 100_000)
            case .priorityAfterIncome:
                BudgetTemplateApplySingleStoredRow(amount: 96_800, goal: 100_000)
            case .noCarryRefill:
                BudgetTemplateApplySingleStoredRow(amount: 10_000, goal: 10_000)
            case .carryRefill:
                BudgetTemplateApplySingleStoredRow(amount: 6_000, goal: 6_000)
            case .copy:
                BudgetTemplateApplySingleStoredRow(amount: 7_300, goal: 7_300)
            case .availablePercent:
                BudgetTemplateApplySingleStoredRow(amount: 9_680, goal: 9_680)
            case .remainderCapped:
                BudgetTemplateApplySingleStoredRow(amount: 10_000)
            case .remainderOpen:
                BudgetTemplateApplySingleStoredRow(amount: 96_800)
            case .goalOnly:
                BudgetTemplateApplySingleStoredRow(amount: 2_500, goal: 50_000, longGoal: 1)
            case .mixedGoal:
                BudgetTemplateApplySingleStoredRow(amount: 8_000, goal: 100_000, longGoal: 1)
            case .orphanGoal:
                BudgetTemplateApplySingleStoredRow(amount: 0)
            }
        }

        var zeroSentinel: BudgetTemplateApplySingleStoredRow {
            BudgetTemplateApplySingleStoredRow(amount: self == .mode ? 77_700 : 0)
        }
    }

    @Test(arguments: TrackingApplySingleCase.allCases)
    func budgetTemplateTrackingApplySingleMatchesActual2681(
        testCase: TrackingApplySingleCase
    ) async throws {
        let fixtureURL = try makeTrackingApplySingleFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.budgetTemplateMessages(
            command: .category(testCase.categoryID),
            month: "2026-07",
            builder: &builder
        )

        #expect(!messages.isEmpty)
        #expect(!messages.contains { $0.dataset == "zero_budgets" })
        _ = try await database.applyLocalSyncMessages(messages)

        #expect(
            try budgetTemplateApplySingleRow(
                table: "reflect_budgets",
                categoryID: testCase.categoryID,
                month: 202607,
                at: fixtureURL
            ) == testCase.expected
        )
        #expect(
            try budgetTemplateApplySingleRow(
                table: "zero_budgets",
                categoryID: testCase.categoryID,
                month: 202607,
                at: fixtureURL
            ) == testCase.zeroSentinel
        )
        #expect(
            try budgetTemplateApplySingleRow(
                table: "zero_budgets",
                categoryID: "copy",
                month: 202606,
                at: fixtureURL
            ) == BudgetTemplateApplySingleStoredRow(amount: 99_900)
        )
    }

    private func makeTrackingApplySingleFixture() throws -> URL {
        try makeSQLiteFixture(extraSQL: """
            UPDATE category_groups SET hidden = 1 WHERE id = 'group';
            UPDATE categories SET hidden = 1 WHERE id = 'groceries';
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE zero_budgets ADD COLUMN goal INTEGER;
            ALTER TABLE zero_budgets ADD COLUMN long_goal INTEGER;

            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('budgetType', 'tracking');
            INSERT INTO preferences VALUES ('defaultCurrencyCode', 'USD');
            INSERT INTO preferences VALUES ('hideFraction', 'false');

            CREATE TABLE reflect_budgets (
                id TEXT PRIMARY KEY,
                month INTEGER,
                category TEXT,
                amount INTEGER,
                carryover INTEGER,
                goal INTEGER,
                long_goal INTEGER
            );

            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 0);
            INSERT INTO category_groups VALUES ('start-group', 'Start', 0, 0, 0, 1);
            INSERT INTO category_groups VALUES ('tracking-group', 'Tracking', 0, 0, 0, 2);
            INSERT INTO category_groups VALUES ('allocation-group', 'Allocation', 0, 0, 0, 3);
            INSERT INTO category_groups VALUES ('goal-group', 'Goals', 0, 0, 0, 4);

            INSERT INTO categories VALUES ('seed', 'Seed', 'income-group', 1, 0, 0, 0, NULL);
            INSERT INTO categories VALUES ('income', 'Income', 'income-group', 1, 0, 0, 1,
                '[{"directive":"template","type":"simple","monthly":1000,"limit":null,"priority":0}]');
            INSERT INTO categories VALUES ('mode', 'Mode', 'start-group', 0, 0, 0, 0,
                '[{"directive":"template","type":"simple","monthly":99,"limit":null,"priority":0}]');
            INSERT INTO categories VALUES ('fixed', 'Fixed', 'tracking-group', 0, 0, 0, 0,
                '[{"directive":"template","type":"simple","monthly":100,"limit":null,"priority":0}]');
            INSERT INTO categories VALUES ('no-carry', 'No Carry', 'tracking-group', 0, 0, 0, 1,
                '[{"directive":"template","type":"limit","amount":100,"period":"monthly","hold":true,"priority":null},{"directive":"template","type":"refill","priority":0}]');
            INSERT INTO categories VALUES ('carry', 'Carry', 'tracking-group', 0, 0, 0, 2,
                '[{"directive":"template","type":"limit","amount":100,"period":"monthly","hold":true,"priority":null},{"directive":"template","type":"refill","priority":0}]');
            INSERT INTO categories VALUES ('copy', 'Copy', 'tracking-group', 0, 0, 0, 3,
                '[{"directive":"template","type":"copy","lookBack":1,"priority":0}]');
            INSERT INTO categories VALUES ('available', 'Available', 'allocation-group', 0, 0, 0, 0,
                '[{"directive":"template","type":"percentage","percent":10,"category":"available funds","previous":false,"priority":0}]');
            INSERT INTO categories VALUES ('priority', 'Priority', 'allocation-group', 0, 0, 0, 1,
                '[{"directive":"template","type":"simple","monthly":1000,"limit":null,"priority":1}]');
            INSERT INTO categories VALUES ('remainder-capped', 'Remainder Capped', 'allocation-group', 0, 0, 0, 2,
                '[{"directive":"template","type":"remainder","weight":1,"limit":{"amount":100,"period":"monthly","hold":true},"priority":null}]');
            INSERT INTO categories VALUES ('remainder-open', 'Remainder Open', 'allocation-group', 0, 0, 0, 3,
                '[{"directive":"template","type":"remainder","weight":1,"limit":null,"priority":null}]');
            INSERT INTO categories VALUES ('goal-only', 'Goal Only', 'goal-group', 0, 0, 0, 0,
                '[{"directive":"goal","type":"goal","amount":500,"priority":0}]');
            INSERT INTO categories VALUES ('mixed-goal', 'Mixed Goal', 'goal-group', 0, 0, 0, 1,
                '[{"directive":"template","type":"simple","monthly":80,"limit":null,"priority":0},{"directive":"goal","type":"goal","amount":1000,"priority":0}]');
            INSERT INTO categories VALUES ('orphan-goal', 'Orphan Goal', 'goal-group', 0, 0, 0, 2, NULL);

            INSERT INTO reflect_budgets VALUES ('202607-seed', 202607, 'seed', 100000, 0, NULL, NULL);
            INSERT INTO reflect_budgets VALUES ('202607-income', 202607, 'income', 0, 0, NULL, NULL);
            INSERT INTO reflect_budgets VALUES ('202607-mode', 202607, 'mode', 700, 0, NULL, NULL);
            INSERT INTO reflect_budgets VALUES ('202607-fixed', 202607, 'fixed', 0, 0, NULL, NULL);
            INSERT INTO reflect_budgets VALUES ('202607-no-carry', 202607, 'no-carry', 0, 0, NULL, NULL);
            INSERT INTO reflect_budgets VALUES ('202607-carry', 202607, 'carry', 0, 0, NULL, NULL);
            INSERT INTO reflect_budgets VALUES ('202607-copy', 202607, 'copy', 0, 0, NULL, NULL);
            INSERT INTO reflect_budgets VALUES ('202607-available', 202607, 'available', 0, 0, NULL, NULL);
            INSERT INTO reflect_budgets VALUES ('202607-priority', 202607, 'priority', 0, 0, NULL, NULL);
            INSERT INTO reflect_budgets VALUES ('202607-remainder-capped', 202607, 'remainder-capped', 0, 0, NULL, NULL);
            INSERT INTO reflect_budgets VALUES ('202607-remainder-open', 202607, 'remainder-open', 0, 0, NULL, NULL);
            INSERT INTO reflect_budgets VALUES ('202607-goal-only', 202607, 'goal-only', 2500, 0, NULL, NULL);
            INSERT INTO reflect_budgets VALUES ('202607-mixed-goal', 202607, 'mixed-goal', 0, 0, NULL, NULL);
            INSERT INTO reflect_budgets VALUES ('202607-orphan-goal', 202607, 'orphan-goal', 0, 0, 33300, NULL);
            INSERT INTO reflect_budgets VALUES ('202606-no-carry', 202606, 'no-carry', 4000, 0, NULL, NULL);
            INSERT INTO reflect_budgets VALUES ('202606-carry', 202606, 'carry', 4000, 1, NULL, NULL);
            INSERT INTO reflect_budgets VALUES ('202606-copy', 202606, 'copy', 7300, 0, NULL, NULL);

            INSERT INTO zero_budgets VALUES (202607, 'income', 0, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202607, 'mode', 77700, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202607, 'fixed', 0, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202607, 'no-carry', 0, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202607, 'carry', 0, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202607, 'copy', 0, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202607, 'available', 0, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202607, 'priority', 0, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202607, 'remainder-capped', 0, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202607, 'remainder-open', 0, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202607, 'goal-only', 0, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202607, 'mixed-goal', 0, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202607, 'orphan-goal', 0, 0, NULL, NULL);
            INSERT INTO zero_budgets VALUES (202606, 'copy', 99900, 0, NULL, NULL);
            """)
    }

}
