import Foundation
import Testing
@testable import Actualist

struct BudgetCategoryVisibilityTests {
    @Test func groupHiddenHidesChildrenWithoutFlippingTheirFlags() {
        let hiddenGroup = group(
            id: "hidden-grp",
            hidden: true,
            categories: [
                category(id: "secret", hidden: false, groupID: "hidden-grp", budgeted: 4_000),
                category(id: "also-hidden", hidden: true, groupID: "hidden-grp", budgeted: 1_000)
            ]
        )

        #expect(BudgetCategoryVisibility.isEffectivelyHidden(category: hiddenGroup.categories[0], group: hiddenGroup))
        #expect(BudgetCategoryVisibility.visibleCategories(in: hiddenGroup).isEmpty)
        #expect(hiddenGroup.categories[0].hidden == false)
        #expect(hiddenGroup.budgeted == 5_000)
    }

    @Test func categoryHiddenHidesOneRowInAVisibleGroup() {
        let bills = group(
            id: "bills",
            hidden: false,
            categories: [
                category(id: "mortgage", hidden: false, budgeted: 10_000),
                category(id: "old", hidden: true, budgeted: 5_000)
            ]
        )

        #expect(BudgetCategoryVisibility.visibleCategories(in: bills).map(\.id) == ["mortgage"])
        #expect(bills.budgeted == 15_000)
    }

    @Test func showHiddenReturnsTheFullExpenseGraph() {
        let groups = [
            group(id: "income", isIncome: true, hidden: false, categories: [
                category(id: "salary", isIncome: true, hidden: false, groupID: "income")
            ]),
            group(id: "bills", hidden: false, categories: [
                category(id: "mortgage", hidden: false),
                category(id: "old", hidden: true)
            ]),
            group(id: "hidden-grp", hidden: true, categories: [
                category(id: "secret", hidden: false, groupID: "hidden-grp")
            ])
        ]

        let hiddenOff = BudgetCategoryVisibility.displayedGroups(from: groups, showHidden: false)
        #expect(hiddenOff.map(\.id) == ["bills"])
        #expect(BudgetCategoryVisibility.displayedCategories(in: hiddenOff[0], showHidden: false).map(\.id) == ["mortgage"])

        let hiddenOn = BudgetCategoryVisibility.displayedGroups(from: groups, showHidden: true)
        #expect(hiddenOn.map(\.id) == ["bills", "hidden-grp"])
        #expect(BudgetCategoryVisibility.displayedCategories(in: hiddenOn[0], showHidden: true).map(\.id) == ["mortgage", "old"])
        #expect(BudgetCategoryVisibility.displayedCategories(in: hiddenOn[1], showHidden: true).map(\.id) == ["secret"])
    }

    @Test func displayedGroupsKeepStoredTotalsWhenRowsAreFiltered() {
        let bills = group(
            id: "bills",
            hidden: false,
            budgeted: 15_000,
            balance: 8_000,
            categories: [
                category(id: "mortgage", hidden: false, budgeted: 10_000, balance: 8_000),
                category(id: "old", hidden: true, budgeted: 5_000, balance: 0)
            ]
        )
        let displayed = BudgetCategoryVisibility.displayedGroups(from: [bills], showHidden: false)
        #expect(displayed.first?.budgeted == 15_000)
        #expect(displayed.first?.balance == 8_000)
        #expect(
            BudgetCategoryVisibility.displayedCategories(in: displayed[0], showHidden: false)
                .reduce(0) { $0 + $1.budgeted } != displayed[0].budgeted
        )
    }

    private func group(
        id: String,
        isIncome: Bool = false,
        hidden: Bool,
        budgeted: Int? = nil,
        balance: Int? = nil,
        categories: [BudgetMonthCategory]
    ) -> BudgetMonthCategoryGroup {
        BudgetMonthCategoryGroup(
            id: id,
            name: id,
            isIncome: isIncome,
            hidden: hidden,
            budgeted: budgeted ?? categories.reduce(0) { $0 + $1.budgeted },
            spent: 0,
            balance: balance ?? categories.reduce(0) { $0 + $1.balance },
            categories: categories
        )
    }

    private func category(
        id: String,
        isIncome: Bool = false,
        hidden: Bool,
        groupID: String = "bills",
        budgeted: Int = 0,
        balance: Int = 0
    ) -> BudgetMonthCategory {
        BudgetMonthCategory(
            id: id,
            name: id,
            isIncome: isIncome,
            hidden: hidden,
            groupID: groupID,
            budgeted: budgeted,
            spent: 0,
            balance: balance,
            carryover: false
        )
    }
}
