import Testing
@testable import Actualist

struct BudgetGridPresentationTests {
    @Test func rowPositionMarksTheEndsOfAGroupCard() {
        let only = GroupedRowPosition(index: 0, count: 1)
        #expect(only.isFirst && only.isLast && !only.showsSeparator)

        let first = GroupedRowPosition(index: 0, count: 3)
        #expect(first.isFirst && !first.isLast && first.showsSeparator)

        let middle = GroupedRowPosition(index: 1, count: 3)
        #expect(!middle.isFirst && !middle.isLast && middle.showsSeparator)

        let last = GroupedRowPosition(index: 2, count: 3)
        #expect(!last.isFirst && last.isLast && !last.showsSeparator)
    }

    @Test func onlyTrackingIncomeGroupsKeepTheirOwnLabels() {
        let envelope = BudgetModePresentation(isTracking: false)
        let tracking = BudgetModePresentation(isTracking: true)

        #expect(!BudgetModePresentation(isTracking: false, isIncome: false).needsOwnLabels(under: envelope))
        #expect(!BudgetModePresentation(isTracking: false, isIncome: true).needsOwnLabels(under: envelope))
        #expect(!BudgetModePresentation(isTracking: true, isIncome: false).needsOwnLabels(under: tracking))
        #expect(BudgetModePresentation(isTracking: true, isIncome: true).needsOwnLabels(under: tracking))
    }

    @Test func rolloverMenuWordingFollowsBudgetTypeAndCurrentState() {
        let envelope = BudgetModePresentation(isTracking: false)
        let tracking = BudgetModePresentation(isTracking: true)
        #expect(envelope.rolloverMenuLabel(isEnabled: false)
            == BudgetRolloverMenuLabel(title: "Roll Over", subtitle: "Overspending carries into next month"))
        #expect(envelope.rolloverMenuLabel(isEnabled: true)
            == BudgetRolloverMenuLabel(title: "Stop Rolling Over", subtitle: "Overspending comes out of next month’s To Budget"))
        #expect(tracking.rolloverMenuLabel(isEnabled: false)
            == BudgetRolloverMenuLabel(title: "Roll Over", subtitle: "The balance carries into next month"))
        #expect(tracking.rolloverMenuLabel(isEnabled: true)
            == BudgetRolloverMenuLabel(title: "Stop Rolling Over", subtitle: "The balance resets each month"))
        #expect(BudgetModePresentation(isTracking: false, isIncome: true).rolloverMenuLabel(isEnabled: false) == nil)
        #expect(BudgetModePresentation(isTracking: true, isIncome: true).rolloverMenuLabel(isEnabled: true) == nil)
    }

    @Test func gridRolloverMenuReadsAndTargetsTheFirstVisibleMonth() throws {
        let off = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 0, hiddenCategoryBalance: 0, visibleCategoryCarryover: false, lastMonthOverspent: 0)
        let on = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 0, hiddenCategoryBalance: 0, visibleCategoryCarryover: true, lastMonthOverspent: 0)
        func loaded(_ month: BudgetMonth, _ id: String) -> LoadedBudgetMonth {
            LoadedBudgetMonth(availableMonths: [id], selectedMonth: id, month: month, alerts: [])
        }
        func presentation(_ snapshots: [String: LoadedBudgetMonth], privacy: Bool = false) -> BudgetGridPresentation {
            BudgetGridPresentation(
                visibleMonths: ["2026-06", "2026-07"],
                snapshots: snapshots,
                privacyEnabled: privacy,
                showHidden: false,
                showTotalAssigned: false,
                includeCarryover: false
            )
        }

        let item = try #require(presentation(["2026-06": loaded(off, "2026-06"), "2026-07": loaded(on, "2026-07")])
            .rolloverMenuItem(categoryID: "mortgage"))
        #expect(item.label.title == "Roll Over")
        #expect(item.month == "2026-06")
        #expect(item.category.id == "mortgage")
        #expect(!item.category.carryover)

        let privateItem = try #require(presentation(["2026-06": loaded(on, "2026-06")], privacy: true)
            .rolloverMenuItem(categoryID: "mortgage"))
        #expect(privateItem.label.title == "Stop Rolling Over")
        #expect(privateItem.category.id == "mortgage")

        // Never fall back to a later month's state while the first one is loading.
        #expect(presentation(["2026-07": loaded(on, "2026-07")]).rolloverMenuItem(categoryID: "mortgage") == nil)
    }

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
