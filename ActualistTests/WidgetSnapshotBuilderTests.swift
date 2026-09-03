import Foundation
import Testing
@testable import Actualist

struct WidgetSnapshotBuilderTests {
    @Test func buildsExpenseCategorySnapshotWithEffectiveVisibilityAndBudgetCurrency() throws {
        let month = makeMonth()
        let snapshot = WidgetSnapshotBuilder.make(
            budgetID: "budget",
            budgetName: "Household",
            month: month,
            currency: .usd,
            privacyEnabled: false,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(snapshot.budgetName == "Household")
        #expect(snapshot.month == "2026-07")
        #expect(snapshot.categories.map(\.id) == ["groceries", "rent"])

        let groceries = try #require(snapshot.categories.first { $0.id == "groceries" })
        #expect(groceries.displayName == "🛒 Groceries")
        #expect(groceries.group == "Everyday")
        #expect(!groceries.isHidden)
        #expect(groceries.availableMinorUnits == 12_345)
        #expect(groceries.formattedAvailable == BudgetCurrency.usd.formatted(12_345))

        let rent = try #require(snapshot.categories.first { $0.id == "rent" })
        #expect(rent.isHidden)
    }

    @Test func privacySnapshotContainsOnlyProjectedDisplayNamesAndAmounts() throws {
        let month = makeMonth()
        let snapshot = WidgetSnapshotBuilder.make(
            budgetID: "budget",
            budgetName: "Private Household",
            month: month,
            currency: .usd,
            privacyEnabled: true,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let projected = BudgetMonthPrivacyProjection.project(month)
        let expectedGroceries = try #require(
            projected.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )
        let groceries = try #require(snapshot.categories.first { $0.id == "groceries" })

        #expect(snapshot.budgetName == PrivacyDisplay.name(for: .budget, seed: "budget"))
        #expect(groceries.displayName == PrivacyDisplay.name(for: .category, seed: "groceries"))
        #expect(groceries.group == PrivacyDisplay.name(for: .categoryGroup, seed: "everyday"))
        #expect(groceries.availableMinorUnits == expectedGroceries.balance)
        #expect(groceries.displayName != "🛒 Groceries")
        #expect(groceries.group != "Everyday")
    }

    private func makeMonth() -> BudgetMonth {
        let groceries = BudgetMonthCategory(
            id: "groceries",
            name: "🛒 Groceries",
            isIncome: false,
            hidden: false,
            groupID: "everyday",
            budgeted: 20_000,
            spent: -7_655,
            balance: 12_345,
            carryover: false
        )
        let rent = BudgetMonthCategory(
            id: "rent",
            name: "Rent",
            isIncome: false,
            hidden: false,
            groupID: "hidden-group",
            budgeted: 100_000,
            spent: -100_000,
            balance: 0,
            carryover: false
        )
        let salary = BudgetMonthCategory(
            id: "salary",
            name: "Salary",
            isIncome: true,
            hidden: false,
            groupID: "income",
            budgeted: 0,
            spent: 250_000,
            balance: 250_000,
            carryover: false
        )
        return BudgetMonth(
            month: "2026-07",
            incomeAvailable: 0,
            lastMonthOverspent: 0,
            forNextMonth: 0,
            totalBudgeted: 120_000,
            toBudget: 0,
            fromLastMonth: 0,
            totalIncome: 250_000,
            totalSpent: -107_655,
            totalBalance: 12_345,
            categoryGroups: [
                BudgetMonthCategoryGroup(
                    id: "everyday",
                    name: "Everyday",
                    isIncome: false,
                    hidden: false,
                    budgeted: 20_000,
                    spent: -7_655,
                    balance: 12_345,
                    categories: [groceries]
                ),
                BudgetMonthCategoryGroup(
                    id: "hidden-group",
                    name: "Fixed",
                    isIncome: false,
                    hidden: true,
                    budgeted: 100_000,
                    spent: -100_000,
                    balance: 0,
                    categories: [rent]
                ),
                BudgetMonthCategoryGroup(
                    id: "income",
                    name: "Income",
                    isIncome: true,
                    hidden: false,
                    budgeted: 0,
                    spent: 250_000,
                    balance: 250_000,
                    categories: [salary]
                )
            ]
        )
    }
}
