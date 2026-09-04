import Testing
@testable import Actualist

struct BudgetGridPresentationTests {
    @Test func oneCategoryAxisIsSharedAcrossVisibleMonthsAndValuesStayExact() throws {
        let month = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: -5,
            hiddenCategoryBalance: 0,
            categoryBudgeted: 123_456,
            categorySpent: 123_461,
            toBudget: 0,
            lastMonthOverspent: 0
        )
        let loaded = LoadedBudgetMonth(availableMonths: ["2026-06"], selectedMonth: "2026-06", month: month, alerts: [])
        let display = BudgetGridPresentation(
            visibleMonths: ["2026-06", "2026-07"],
            snapshots: ["2026-06": loaded, "2026-07": loaded],
            privacyEnabled: false,
            showHidden: false,
            showTotalAssigned: true,
            includeCarryover: false
        )

        #expect(display.groups.count == 1)
        #expect(display.groups[0].categories.map(\.id) == ["mortgage"])
        #expect(display.months.count == 2)
        #expect(display.months.allSatisfy { display.category("mortgage", month: $0)?.balance == -5 })
        #expect(display.months[0].assignedText != nil)
    }

    @Test func privacyProjectionHidesRealCategoryNamesAndUsesCurrency() throws {
        let month = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 1_234_567,
            hiddenCategoryBalance: 0,
            categoryBudgeted: 1_234_567,
            categorySpent: 0,
            lastMonthOverspent: 0
        )
        let loaded = LoadedBudgetMonth(availableMonths: ["2026-06"], selectedMonth: "2026-06", month: month, alerts: [])
        let display = BudgetGridPresentation(
            visibleMonths: ["2026-06"], snapshots: ["2026-06": loaded],
            privacyEnabled: true, showHidden: false, showTotalAssigned: true, includeCarryover: false
        )

        #expect(display.groups[0].title != "Monthly Bills")
        #expect(display.groups[0].categories[0].title != "Mortgage")
        #expect(display.months[0].assignedText?.contains("$") == true)
    }

    @Test func hiddenGroupsAndCategoriesAreExcludedButShownWhenRequested() {
        let category = BudgetMonthCategory(
            id: "hidden-category", name: "Hidden", isIncome: false, hidden: true,
            groupID: "hidden-group", budgeted: 0, spent: 0, balance: 0, carryover: false
        )
        let group = BudgetMonthCategoryGroup(
            id: "hidden-group", name: "Hidden Group", isIncome: false, hidden: true,
            budgeted: 0, spent: 0, balance: 0, categories: [category]
        )
        let month = BudgetMonth(
            month: "2026-06", incomeAvailable: 0, lastMonthOverspent: 0, forNextMonth: 0,
            totalBudgeted: 0, toBudget: 0, fromLastMonth: 0, totalIncome: 0, totalSpent: 0,
            totalBalance: 0, categoryGroups: [group]
        )
        let loaded = LoadedBudgetMonth(availableMonths: ["2026-06"], selectedMonth: "2026-06", month: month, alerts: [])
        let hidden = BudgetGridPresentation(visibleMonths: ["2026-06"], snapshots: ["2026-06": loaded], privacyEnabled: false, showHidden: false, showTotalAssigned: false, includeCarryover: false)
        let shown = BudgetGridPresentation(visibleMonths: ["2026-06"], snapshots: ["2026-06": loaded], privacyEnabled: false, showHidden: true, showTotalAssigned: false, includeCarryover: false)

        #expect(hidden.groups.isEmpty)
        #expect(shown.groups.count == 1)
        #expect(shown.groups[0].categories.count == 1)
    }

    @Test func missingMonthUsesPlaceholderAndEmptyBudgetHasNoGroups() {
        let missing = BudgetGridPresentation(
            visibleMonths: ["2026-06"], snapshots: [:], errors: ["2026-06": "Timed out"],
            privacyEnabled: false, showHidden: false, showTotalAssigned: false, includeCarryover: false
        )
        #expect(missing.months[0].snapshot == nil)
        #expect(missing.months[0].error == "Timed out")
        #expect(missing.months[0].toBudgetText == "—")
        #expect(missing.groups.isEmpty)
    }

    @Test func monthAlertsBelongToTheirMonthAndExcludeZeroToBudget() throws {
        let month = try BudgetViewModelFixtures.decodeBudgetMonth(visibleCategoryBalance: 0, hiddenCategoryBalance: 0, lastMonthOverspent: 0)
        let alert = BudgetMonthAlert(kind: "uncategorizedTransactions", severity: "warning", title: "Needs category", amount: nil, count: 2, actionTitle: "Review")
        let loaded = LoadedBudgetMonth(availableMonths: ["2026-06"], selectedMonth: "2026-06", month: month, alerts: [alert])
        let display = BudgetGridPresentation(visibleMonths: ["2026-06"], snapshots: ["2026-06": loaded], privacyEnabled: false, showHidden: false, showTotalAssigned: false, includeCarryover: false)
        #expect(display.months[0].alerts.map(\.kind) == [.uncategorizedTransactions])
        #expect(!display.months[0].alerts.contains { $0.kind == .toBudget })
    }

    @Test func longNamesAndManyCategoriesRemainOnOneSharedGroupAxis() {
        let categories = (0..<24).map { index in
            BudgetMonthCategory(
                id: "category-\(index)",
                name: index == 0 ? "A very long category name that must remain identifiable" : "Category \(index)",
                isIncome: false,
                hidden: false,
                groupID: "group",
                budgeted: index == 23 ? Int.max : 0,
                spent: 0,
                balance: index == 23 ? Int.max : 0,
                carryover: false
            )
        }
        let group = BudgetMonthCategoryGroup(id: "group", name: "Group", isIncome: false, hidden: false, budgeted: 0, spent: 0, balance: 0, categories: categories)
        let month = BudgetMonth(month: "2026-06", incomeAvailable: 0, lastMonthOverspent: 0, forNextMonth: 0, totalBudgeted: 0, toBudget: 0, fromLastMonth: 0, totalIncome: 0, totalSpent: 0, totalBalance: 0, categoryGroups: [group])
        let loaded = LoadedBudgetMonth(availableMonths: ["2026-06"], selectedMonth: "2026-06", month: month, alerts: [])
        let display = BudgetGridPresentation(visibleMonths: ["2026-06"], snapshots: ["2026-06": loaded], privacyEnabled: false, showHidden: false, showTotalAssigned: false, includeCarryover: false)

        #expect(display.groups.count == 1)
        #expect(display.groups[0].categories.count == 24)
        #expect(display.groups[0].categories[0].title.contains("long category name"))
        #expect(display.category("category-23", month: display.months[0])?.balance == Int.max)
    }
}
