import Foundation
import Testing
@testable import Actualist

@MainActor
struct BudgetViewModelDisplayTests {
    @Test func initialCachedMonthIsReadyForTheFirstFrame() throws {
        let loaded = LoadedBudgetMonth(
            availableMonths: ["2026-06"],
            selectedMonth: "2026-06",
            month: try BudgetViewModelFixtures.decodeBudgetMonth(
                visibleCategoryBalance: 37_655,
                hiddenCategoryBalance: 0,
                lastMonthOverspent: 0
            ),
            alerts: []
        )

        let model = BudgetViewModel(initialMonth: loaded)

        #expect(!model.isLoading)
        #expect(model.selectedMonth == "2026-06")
        #expect(model.budgetMonth == loaded.month)
        #expect(model.availableMonths == ["2026-06"])
    }

    @Test func derivesVisibleGroupsAndOverspendingCount() throws {
        let model = BudgetViewModel()
        model.budgetMonth = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: -2500,
            hiddenCategoryBalance: -5000,
            lastMonthOverspent: 0
        )

        #expect(model.visibleGroups.count == 1)
        #expect(model.visibleGroups.first?.visibleCategories.count == 1)
        #expect(model.overspendingAlertCount == 1)
    }

    @Test func derivesPriorMonthOverspendingWhenNoVisibleCategoryIsOverspent() throws {
        let model = BudgetViewModel()
        model.budgetMonth = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 1000,
            hiddenCategoryBalance: -5000,
            toBudget: 0,
            lastMonthOverspent: -1000
        )

        #expect(model.overspendingAlertCount == 1)
    }

    @Test func rolloverOverspendingIsExcludedByDefaultAndCanBeIncluded() async throws {
        let month = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: -2_500,
            hiddenCategoryBalance: 0,
            visibleCategoryCarryover: true,
            lastMonthOverspent: 0
        )
        let loadedMonth = LoadedBudgetMonth(
            availableMonths: ["2026-06"],
            selectedMonth: "2026-06",
            month: month,
            alerts: [
                BudgetMonthAlert(
                    kind: "overspending",
                    severity: "danger",
                    title: "Overspent categories",
                    amount: nil,
                    count: 1,
                    actionTitle: "Cover"
                )
            ]
        )
        let model = BudgetViewModel()

        await model.load(
            budgetID: "budget",
            repository: RecordingBudgetRepository(loadedMonth: loadedMonth)
        )

        #expect(model.overspentCategoryOptions.isEmpty)
        #expect(model.budgetAlerts.allSatisfy { $0.kind != .overspending })

        model.includeCarryoverCategoriesInOverspentAlerts = true

        #expect(model.overspentCategoryOptions.map(\.id) == ["mortgage"])
        #expect(model.budgetAlerts.first(where: { $0.kind == .overspending })?.count == 1)
    }

    @Test func buildsReusableBudgetAlerts() throws {
        let alerts = [
            BudgetAlert(
                alert: BudgetMonthAlert(
                    kind: "toBudget",
                    severity: "positive",
                    title: "To Budget",
                    amount: 1500,
                    count: nil,
                    actionTitle: nil
                )
            ),
            BudgetAlert(
                alert: BudgetMonthAlert(
                    kind: "overspending",
                    severity: "danger",
                    title: "Overspent categories",
                    amount: nil,
                    count: 1,
                    actionTitle: "Cover"
                )
            ),
            BudgetAlert(
                alert: BudgetMonthAlert(
                    kind: "uncategorizedTransactions",
                    severity: "warning",
                    title: "Uncategorized transactions",
                    amount: nil,
                    count: 3,
                    actionTitle: "Review"
                )
            )
        ].compactMap { $0 }

        #expect(alerts.map(\.kind) == [
            .toBudget,
            .overspending,
            .uncategorizedTransactions
        ])
        #expect(alerts.first?.title == "To Budget")
        #expect(alerts.first?.severity == .positive)
        #expect(alerts.first?.valueText?.contains("15.00") == true)
        #expect(alerts.last?.count == 3)
        #expect(alerts.last?.actionTitle == "Review")
        #expect(alerts.last?.severity == .warning)
    }

    @Test func ignoresUnknownBudgetAlertKinds() {
        let alert = BudgetAlert(
            alert: BudgetMonthAlert(
                kind: "futureAlert",
                severity: "warning",
                title: "Future Alert",
                amount: nil,
                count: 1,
                actionTitle: "Open"
            )
        )

        #expect(alert == nil)
    }

    @Test func loadIncludesSelectedMonthWhenRepositoryOmitsAvailableMonths() async throws {
        let loadedMonth = LoadedBudgetMonth(
            availableMonths: [],
            selectedMonth: "2026-06",
            month: try BudgetViewModelFixtures.decodeBudgetMonth(
                visibleCategoryBalance: 1_000,
                hiddenCategoryBalance: 0,
                lastMonthOverspent: 0
            ),
            alerts: []
        )
        let model = BudgetViewModel()

        await model.load(budgetID: "budget", repository: RecordingBudgetRepository(loadedMonth: loadedMonth))

        #expect(model.selectedMonth == "2026-06")
        #expect(model.availableMonths == ["2026-06"])
    }

    @Test func loadCanonicalizesAvailableMonthsForPicker() async throws {
        let loadedMonth = LoadedBudgetMonth(
            availableMonths: ["202606", "2026-7", "2026/08/15", "not-a-month"],
            selectedMonth: "2026-06",
            month: try BudgetViewModelFixtures.decodeBudgetMonth(
                visibleCategoryBalance: 1_000,
                hiddenCategoryBalance: 0,
                lastMonthOverspent: 0
            ),
            alerts: []
        )
        let model = BudgetViewModel()

        await model.load(budgetID: "budget", repository: RecordingBudgetRepository(loadedMonth: loadedMonth))

        #expect(model.availableMonths == ["2026-06", "2026-07", "2026-08"])
    }

    @Test func allVisibleGroupsStartExpandedAndManualCollapseSurvivesSameMonthReload() async throws {
        let baseMonth = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 1_000,
            hiddenCategoryBalance: 0,
            lastMonthOverspent: 0
        )
        let lowerGroups = [
            BudgetMonthCategoryGroup(
                id: "food",
                name: "Food",
                isIncome: false,
                hidden: false,
                budgeted: 0,
                spent: 0,
                balance: 0,
                categories: []
            ),
            BudgetMonthCategoryGroup(
                id: "savings",
                name: "Savings",
                isIncome: false,
                hidden: false,
                budgeted: 0,
                spent: 0,
                balance: 0,
                categories: []
            ),
            BudgetMonthCategoryGroup(
                id: "last-group",
                name: "Last Group",
                isIncome: false,
                hidden: false,
                budgeted: 0,
                spent: 0,
                balance: 0,
                categories: []
            )
        ]
        let month = BudgetMonth(
            month: baseMonth.month,
            incomeAvailable: baseMonth.incomeAvailable,
            lastMonthOverspent: baseMonth.lastMonthOverspent,
            forNextMonth: baseMonth.forNextMonth,
            totalBudgeted: baseMonth.totalBudgeted,
            toBudget: baseMonth.toBudget,
            fromLastMonth: baseMonth.fromLastMonth,
            totalIncome: baseMonth.totalIncome,
            totalSpent: baseMonth.totalSpent,
            totalBalance: baseMonth.totalBalance,
            categoryGroups: baseMonth.categoryGroups + lowerGroups
        )
        let loadedMonth = LoadedBudgetMonth(
            availableMonths: ["2026-06"],
            selectedMonth: "2026-06",
            month: month,
            alerts: []
        )
        let repository = RecordingBudgetRepository(loadedMonth: loadedMonth)
        let model = BudgetViewModel()

        await model.load(budgetID: "budget", repository: repository)
        #expect(model.expandedGroupIDs == ["bills", "food", "savings", "last-group"])

        let savings = try #require(model.budgetMonth?.categoryGroups.first { $0.id == "savings" })
        #expect(model.isExpanded(savings))
        model.toggle(savings)
        #expect(!model.isExpanded(savings))

        await model.load(budgetID: "budget", repository: repository)

        #expect(!model.isExpanded(savings))
        #expect(model.expandedGroupIDs == ["bills", "food", "last-group"])
    }

    @Test func switchingBudgetsInSameMonthExpandsAllReplacementGroups() async throws {
        let originalMonth = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 1_000,
            hiddenCategoryBalance: 0,
            lastMonthOverspent: 0
        )
        let replacementGroup = BudgetMonthCategoryGroup(
            id: "replacement-group",
            name: "Replacement Group",
            isIncome: false,
            hidden: false,
            budgeted: 0,
            spent: 0,
            balance: 0,
            categories: []
        )
        let replacementMonth = BudgetMonth(
            month: originalMonth.month,
            incomeAvailable: originalMonth.incomeAvailable,
            lastMonthOverspent: originalMonth.lastMonthOverspent,
            forNextMonth: originalMonth.forNextMonth,
            totalBudgeted: originalMonth.totalBudgeted,
            toBudget: originalMonth.toBudget,
            fromLastMonth: originalMonth.fromLastMonth,
            totalIncome: originalMonth.totalIncome,
            totalSpent: originalMonth.totalSpent,
            totalBalance: originalMonth.totalBalance,
            categoryGroups: [replacementGroup]
        )
        let model = BudgetViewModel()

        await model.load(
            budgetID: "original-budget",
            repository: RecordingBudgetRepository(
                loadedMonth: LoadedBudgetMonth(
                    availableMonths: [originalMonth.month],
                    selectedMonth: originalMonth.month,
                    month: originalMonth,
                    alerts: []
                )
            )
        )
        model.expandedGroupIDs = []

        await model.load(
            budgetID: "replacement-budget",
            repository: RecordingBudgetRepository(
                loadedMonth: LoadedBudgetMonth(
                    availableMonths: [replacementMonth.month],
                    selectedMonth: replacementMonth.month,
                    month: replacementMonth,
                    alerts: []
                )
            )
        )

        #expect(model.expandedGroupIDs == ["replacement-group"])
    }

    @Test func omitsZeroToBudgetAlert() throws {
        let model = BudgetViewModel()
        model.budgetMonth = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 1000,
            hiddenCategoryBalance: 0,
            toBudget: 0,
            lastMonthOverspent: 0
        )

        #expect(model.budgetAlerts.isEmpty)
        #expect(
            BudgetMonthSummaryPresentation.alerts(
                from: model.budgetAlerts,
                month: model.budgetMonth,
                showTotalAssigned: false
            ).isEmpty
        )
    }
}

struct BudgetMonthSummaryPresentationTests {
    @Test func disabledSettingLeavesLoadedAlertsUnchanged() {
        let month = makeMonth(toBudget: 0, totalBudgeted: 12_847_42)
        let loaded = [
            BudgetAlert(
                kind: .overspending,
                title: "Overspent",
                count: 2,
                actionTitle: "Cover",
                severity: .danger
            )
        ]

        #expect(
            BudgetMonthSummaryPresentation.alerts(
                from: loaded,
                month: month,
                showTotalAssigned: false
            ) == loaded
        )
        #expect(
            BudgetMonthSummaryPresentation.assignedValueText(
                for: loaded[0],
                month: month,
                showTotalAssigned: false,
                isPrivacyModeEnabled: false
            ) == nil
        )
    }

    @Test func enabledSettingInsertsZeroToBudgetAlertWithoutDuplicating() {
        let month = makeMonth(toBudget: 0, totalBudgeted: 12_847_42)
        let overspent = BudgetAlert(
            kind: .overspending,
            title: "Overspent",
            count: 1,
            actionTitle: "Cover",
            severity: .danger
        )

        let inserted = BudgetMonthSummaryPresentation.alerts(
            from: [overspent],
            month: month,
            showTotalAssigned: true
        )
        #expect(inserted.map(\.kind) == [.toBudget, .overspending])
        #expect(inserted.first?.valueText == 0.actualMoney.formatted())
        #expect(inserted.first?.severity == .positive)

        let existing = BudgetAlert(
            kind: .toBudget,
            title: "To Budget",
            valueText: 200_83.actualMoney.formatted(),
            actionTitle: nil,
            severity: .positive
        )
        #expect(
            BudgetMonthSummaryPresentation.alerts(
                from: [existing],
                month: month,
                showTotalAssigned: true
            ) == [existing]
        )
    }

    @Test func assignedValueUsesMonthTotalBudgetedAndUpdatesWithMonth() {
        let july = makeMonth(toBudget: 200_83, totalBudgeted: 12_847_42, month: "2026-07")
        let august = makeMonth(toBudget: 0, totalBudgeted: 32_000, month: "2026-08")
        let alert = BudgetAlert(
            kind: .toBudget,
            title: "To Budget",
            valueText: july.toBudget.actualMoney.formatted(),
            actionTitle: nil,
            severity: .positive
        )

        #expect(
            BudgetMonthSummaryPresentation.assignedValueText(
                for: alert,
                month: july,
                showTotalAssigned: true,
                isPrivacyModeEnabled: false
            ) == 12_847_42.actualMoney.formatted()
        )
        #expect(
            BudgetMonthSummaryPresentation.assignedValueText(
                for: alert,
                month: august,
                showTotalAssigned: true,
                isPrivacyModeEnabled: false
            ) == 32_000.actualMoney.formatted()
        )
    }

    @Test func assignedValueUsesPrivacyDisplayWhenEnabled() {
        let month = makeMonth(toBudget: 200_83, totalBudgeted: 12_847_42)
        let alert = BudgetAlert(
            kind: .toBudget,
            title: "To Budget",
            valueText: month.toBudget.actualMoney.formatted(),
            actionTitle: nil,
            severity: .positive
        )

        #expect(
            BudgetMonthSummaryPresentation.assignedValueText(
                for: alert,
                month: month,
                showTotalAssigned: true,
                isPrivacyModeEnabled: true
            ) == PrivacyDisplay.money(
                month.totalBudgeted,
                seed: "budget-alert-assigned-\(month.month)",
                maximumDollars: 900
            )
        )
    }

    private func makeMonth(toBudget: Int, totalBudgeted: Int, month: String = "2026-07") -> BudgetMonth {
        BudgetMonth(
            month: month,
            incomeAvailable: toBudget,
            lastMonthOverspent: 0,
            forNextMonth: 0,
            totalBudgeted: totalBudgeted,
            toBudget: toBudget,
            fromLastMonth: 0,
            totalIncome: 0,
            totalSpent: 0,
            totalBalance: 0,
            categoryGroups: []
        )
    }
}
