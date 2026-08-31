import Testing
@testable import Actualist

@MainActor
struct BudgetTemplateActionAvailabilityTests {
    @Test func monthVisibilityMatchesWholeBudgetApplyScope() {
        let hiddenExpense = BudgetMonthCategory(
            id: "hidden-expense",
            name: "Hidden Expense",
            isIncome: false,
            hidden: true,
            groupID: "expenses",
            budgeted: 0,
            spent: 0,
            balance: 0,
            carryover: false,
            hasTemplateDefinition: true
        )
        let income = BudgetMonthCategory(
            id: "income",
            name: "Income",
            isIncome: true,
            hidden: false,
            groupID: "income-group",
            budgeted: 0,
            spent: 0,
            balance: 0,
            carryover: false,
            hasTemplateDefinition: true
        )
        let groups = [
            BudgetMonthCategoryGroup(
                id: "expenses",
                name: "Expenses",
                isIncome: false,
                hidden: false,
                budgeted: 0,
                spent: 0,
                balance: 0,
                categories: [hiddenExpense]
            ),
            BudgetMonthCategoryGroup(
                id: "income-group",
                name: "Income",
                isIncome: true,
                hidden: false,
                budgeted: 0,
                spent: 0,
                balance: 0,
                categories: [income]
            )
        ]
        let month = BudgetMonth(
            month: "2026-06",
            incomeAvailable: 0,
            lastMonthOverspent: 0,
            forNextMonth: 0,
            totalBudgeted: 0,
            toBudget: 0,
            fromLastMonth: 0,
            totalIncome: 0,
            totalSpent: 0,
            totalBalance: 0,
            categoryGroups: groups
        )

        #expect(!BudgetTemplateActionAvailability.hasMonthActions(in: month, isTrackingBudget: false))
        #expect(BudgetTemplateActionAvailability.hasMonthActions(in: month, isTrackingBudget: true))
        #expect(BudgetTemplateActionAvailability.hasCategoryAction(for: hiddenExpense.id, in: groups))
    }

    @Test func budgetDatabaseDetectsStoredTemplateDefinitions() async throws {
        let fixtureURL = try LocalFirstActualStoreTests().makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":50,"priority":0}]'
            WHERE id = 'groceries';
            INSERT INTO categories VALUES ('empty', 'Empty', 'group', 0, 0, 0, 2, '[]');
            INSERT INTO categories VALUES ('malformed', 'Malformed', 'group', 0, 0, 0, 3, 'not-json');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let month = try await database.fetchBudgetMonth(month: "2026-07")
        let categories = Dictionary(
            uniqueKeysWithValues: month.categoryGroups.flatMap(\.categories).map { ($0.id, $0) }
        )

        #expect(categories["groceries"]?.hasTemplateDefinition == true)
        #expect(categories["empty"]?.hasTemplateDefinition == false)
        #expect(categories["malformed"]?.hasTemplateDefinition == true)
    }
}
