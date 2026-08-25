import Foundation
import Testing
@testable import Actualist

struct BudgetMonthPrivacyProjectionTests {
    @Test func disabledSettingReturnsTheRealMonth() {
        let month = makeMonth()

        #expect(BudgetMonthPrivacyProjection.displayMonth(month, isEnabled: false) == month)
        #expect(BudgetMonthPrivacyProjection.displayMonth(nil, isEnabled: true) == nil)
    }

    @Test func categoryAvailableEqualsAssignedPlusSpentPlusLeftover() {
        let month = makeMonth()
        let projected = BudgetMonthPrivacyProjection.project(month)

        for category in projected.categoryGroups.flatMap(\.categories) {
            let leftover = PrivacyDisplay.amount(
                leftoverSign(month: month.month, categoryID: category.id),
                seed: "budget-leaf-leftover-\(month.month)-\(category.id)",
                maximumDollars: 400
            )
            let budgeted = category.isIncome
                ? 0
                : PrivacyDisplay.amount(
                    1,
                    seed: "budget-leaf-budgeted-\(month.month)-\(category.id)",
                    maximumDollars: 900
                )
            let spent = PrivacyDisplay.amount(
                category.isIncome ? 1 : -1,
                seed: "budget-leaf-spent-\(month.month)-\(category.id)",
                maximumDollars: 600
            )
            #expect(category.budgeted == budgeted)
            #expect(category.spent == spent)
            #expect(category.balance == budgeted + spent + leftover)
        }
    }

    @Test func groupAndMonthTotalsAreSumsOfLeaves() {
        let projected = BudgetMonthPrivacyProjection.project(makeMonth())
        let expenseGroups = projected.categoryGroups.filter { !$0.isIncome }
        let incomeGroups = projected.categoryGroups.filter(\.isIncome)

        for group in projected.categoryGroups {
            #expect(group.budgeted == group.categories.reduce(0) { $0 + $1.budgeted })
            #expect(group.spent == group.categories.reduce(0) { $0 + $1.spent })
            #expect(group.balance == group.categories.reduce(0) { $0 + $1.balance })
        }

        #expect(projected.totalBudgeted == expenseGroups.reduce(0) { $0 + $1.budgeted })
        #expect(projected.totalSpent == expenseGroups.reduce(0) { $0 + $1.spent })
        #expect(projected.totalBalance == expenseGroups.reduce(0) { $0 + $1.balance })
        #expect(projected.totalIncome == incomeGroups.reduce(0) { $0 + $1.spent })
        #expect(projected.incomeAvailable == projected.toBudget)
    }

    @Test func incomeIsUnassignedAndSignsFollowEnvelopeRoles() {
        let projected = BudgetMonthPrivacyProjection.project(makeMonth())

        for category in projected.categoryGroups.flatMap(\.categories) {
            if category.isIncome {
                #expect(category.budgeted == 0)
                #expect(category.spent > 0)
            } else {
                #expect(category.budgeted > 0)
                #expect(category.spent < 0)
            }
        }
    }

    @Test func projectionIsDeterministicAndChangesWithMonth() {
        let july = makeMonth(month: "2026-07")
        let august = makeMonth(month: "2026-08")

        let first = BudgetMonthPrivacyProjection.project(july)
        let second = BudgetMonthPrivacyProjection.project(july)
        let otherMonth = BudgetMonthPrivacyProjection.project(august)

        #expect(first == second)
        #expect(first.totalBudgeted != july.totalBudgeted)
        #expect(first.totalBudgeted != otherMonth.totalBudgeted)
        #expect(first.toBudget != otherMonth.toBudget)
    }

    private func leftoverSign(month: String, categoryID: String) -> Int {
        PrivacyDisplay.stableHash("budget-leaf-leftover-sign-\(month)-\(categoryID)") % 2 == 0
            ? 1
            : -1
    }

    private func makeMonth(month: String = "2026-07") -> BudgetMonth {
        let dining = BudgetMonthCategory(
            id: "dining",
            name: "Dining",
            isIncome: false,
            hidden: false,
            groupID: "everyday",
            budgeted: 10_000,
            spent: -4_000,
            balance: 6_000,
            carryover: false
        )
        let hidden = BudgetMonthCategory(
            id: "hidden-cat",
            name: "Hidden",
            isIncome: false,
            hidden: true,
            groupID: "everyday",
            budgeted: 5_000,
            spent: -1_000,
            balance: 4_000,
            carryover: false
        )
        let vacation = BudgetMonthCategory(
            id: "vacation",
            name: "Vacation",
            isIncome: false,
            hidden: false,
            groupID: "goals",
            budgeted: 20_000,
            spent: 0,
            balance: 25_000,
            carryover: true
        )
        let salary = BudgetMonthCategory(
            id: "salary",
            name: "Salary",
            isIncome: true,
            hidden: false,
            groupID: "income",
            budgeted: 0,
            spent: 80_000,
            balance: 80_000,
            carryover: false
        )

        return BudgetMonth(
            month: month,
            incomeAvailable: 200_83,
            lastMonthOverspent: 0,
            forNextMonth: 1_500,
            totalBudgeted: 35_000,
            toBudget: 200_83,
            fromLastMonth: 0,
            totalIncome: 80_000,
            totalSpent: -5_000,
            totalBalance: 35_000,
            categoryGroups: [
                BudgetMonthCategoryGroup(
                    id: "everyday",
                    name: "Everyday",
                    isIncome: false,
                    hidden: false,
                    budgeted: 15_000,
                    spent: -5_000,
                    balance: 10_000,
                    categories: [dining, hidden]
                ),
                BudgetMonthCategoryGroup(
                    id: "goals",
                    name: "Goals",
                    isIncome: false,
                    hidden: false,
                    budgeted: 20_000,
                    spent: 0,
                    balance: 25_000,
                    categories: [vacation]
                ),
                BudgetMonthCategoryGroup(
                    id: "income",
                    name: "Income",
                    isIncome: true,
                    hidden: false,
                    budgeted: 0,
                    spent: 80_000,
                    balance: 80_000,
                    categories: [salary]
                )
            ]
        )
    }
}
