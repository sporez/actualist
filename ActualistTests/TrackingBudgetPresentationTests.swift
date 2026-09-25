import Foundation
import Testing
@testable import Actualist

@MainActor
struct TrackingBudgetPresentationTests {
    static func month(_ id: String = "2026-08") throws -> BudgetMonth {
        let salary = BudgetMonthCategory(id: "salary", name: "Private Salary", isIncome: true, hidden: false,
            groupID: "income", budgeted: 500_000, spent: 450_000, balance: 50_000, carryover: true)
        let food = BudgetMonthCategory(id: "food", name: "Private Food", isIncome: false, hidden: false,
            groupID: "expenses", budgeted: 60_000, spent: -70_000, balance: -10_000, carryover: false)
        let hidden = BudgetMonthCategory(id: "hidden", name: "Private Hidden", isIncome: false, hidden: true,
            groupID: "expenses", budgeted: 1_000, spent: -2_000, balance: -1_000, carryover: false)
        let groups = [
            BudgetMonthCategoryGroup(id: "income", name: "Income", isIncome: true, hidden: false,
                budgeted: salary.budgeted, spent: salary.spent, balance: salary.balance, categories: [salary]),
            BudgetMonthCategoryGroup(id: "expenses", name: "Expenses", isIncome: false, hidden: false,
                budgeted: food.budgeted, spent: food.spent, balance: food.balance, categories: [food, hidden])
        ]
        let totals = try BudgetFinancialCalculation.totals(groups: groups, table: .tracking)
        return BudgetMonth(month: id, incomeAvailable: 0, lastMonthOverspent: 0, forNextMonth: 0,
            totalBudgeted: totals.budgeted, toBudget: 0, fromLastMonth: 0, totalIncome: totals.income,
            totalSpent: totals.spent, totalBalance: totals.balance, categoryGroups: groups, trackingSummary: totals.tracking)
    }

    static func loaded(_ month: BudgetMonth) -> LoadedBudgetMonth {
        LoadedBudgetMonth(modeIdentity: .init(storageID: "demo", table: .tracking, revision: "tracking"),
            availableMonths: [month.month], selectedMonth: month.month, month: month, alerts: [], isTrackingBudget: true)
    }

    @Test func privacyAssignmentNeverDisplaysOriginalAmountOrChangesCommand() throws {
        let real = try Self.month().categoryGroups[0].categories[0]
        let sample = BudgetMonthPrivacyProjection.project(category: real, month: "2026-08", currency: .usd, table: .tracking)
        let workflow = BudgetAssignmentWorkflow()
        workflow.begin(for: real, budgetID: "demo", month: "2026-08")
        #expect(workflow.amountDisplay(for: sample, currency: .usd, randomized: true).primaryText == BudgetCurrency.usd.formatted(sample.budgeted))
        workflow.setInputMode(.addition)
        workflow.appendDigit(1)
        #expect(workflow.amountDisplay(for: sample, currency: .usd, randomized: true).primaryText == BudgetCurrency.usd.formatted(sample.budgeted))
        #expect(workflow.draft?.validatedFinalBudgeted == real.budgeted + 1)
    }

    @Test func summarySelectsPlannedAndActualWithoutChangingTemplateSavings() throws {
        let month = try Self.month()
        let open = try #require(BudgetSavingsPresentation(month: month, currency: .usd, currentMonth: "2026-08"))
        let closed = try #require(BudgetSavingsPresentation(month: month, currency: .usd, currentMonth: "2026-09"))
        #expect(open.title == "Projected Savings")
        #expect(open.amount == 440_000)
        #expect(closed.title == "Saved")
        #expect(closed.amount == 380_000)
        #expect(open.incomeText != closed.incomeText)
        #expect(month.trackingSummary?.plannedSavings == 440_000)
    }

    @Test func privacySamplesShareTrackingTotalsAndDetailsAcrossCurrencies() throws {
        for currency in [BudgetCurrency.usd, .none, BudgetCurrency(code: "JPY", decimalPlaces: 0, hideFraction: false)] {
            let month = try Self.month()
            let sample = BudgetMonthPrivacyProjection.project(month, currency: currency)
            let totals = try BudgetFinancialCalculation.totals(groups: sample.categoryGroups, table: .tracking)
            #expect(sample.trackingSummary == totals.tracking)
            #expect(sample.toBudget == 0)
            #expect(sample.totalIncome != month.totalIncome)
            let income = sample.categoryGroups[0].categories[0]
            #expect(income.budgeted > 0)
            #expect(income.balance == income.budgeted - income.spent)
            let expense = sample.categoryGroups[1].categories[0]
            #expect(expense.balance == expense.budgeted + expense.spent)
            let hidden = sample.categoryGroups[1].categories[1]
            #expect(sample.totalBudgeted == sample.categoryGroups[1].categories[0].budgeted)
            #expect(hidden.budgeted > 0)
            let details = CategoryMonthDetails(category: month.categoryGroups[0].categories[0], month: month.month,
                modeIdentity: Self.loaded(month).modeIdentity)
            let projected = AccountTransactionFeedProjection(scope: .category(details), loaded: nil,
                activePage: nil, statusFilter: .all, query: "",
                pendingNewTransactionIDs: [], privacyModeEnabled: true, currency: currency).displayState
            #expect(projected.categorySummary?.budgetedText == currency.formatted(income.budgeted))
            #expect(projected.categorySummary?.spentText == currency.formatted(income.spent))
            #expect(projected.title != details.category.name)
        }
    }

    @Test func incomeAppearsExpandedAndEditsPastMonthInBothLayouts() async throws {
        let snapshot = Self.loaded(try Self.month())
        let model = BudgetViewModel(initialMonth: snapshot, initialBudgetID: "demo")
        let income = snapshot.month.categoryGroups[0]
        #expect(model.visibleGroups.contains { $0.isIncome })
        #expect(model.isExpanded(income))
        model.toggle(income)
        #expect(!model.isExpanded(income))
        model.beginAssignmentEditing(for: income.categories[0])
        #expect(model.activeCategoryMonthDetails?.spentAmount == 450_000)
        #expect(model.activeCategoryMonthDetails?.semantics.showsBalance == false)
        let repository = RecordingBudgetRepository(loadedMonth: snapshot)
        let viewport = BudgetViewportModel(repository: repository)
        await viewport.load(budgetID: "demo", anchorMonth: snapshot.month.month)
        #expect(viewport.expandedGroupIDs.contains(income.id))
        viewport.beginAssignmentEditing(categoryID: "salary", month: snapshot.month.month)
        #expect(viewport.assignmentWorkflow.isPresented)
        #expect(viewport.assignmentWorkflow.context?.modeIdentity == snapshot.modeIdentity)
    }

    @Test func partiallyLoadedGridKeepsIncomeHierarchyFromAvailableSnapshot() throws {
        let snapshot = Self.loaded(try Self.month())
        let grid = BudgetGridPresentation(visibleMonths: ["2026-07", "2026-08"], snapshots: ["2026-08": snapshot],
            privacyEnabled: false, showHidden: false, showTotalAssigned: false, includeCarryover: false)
        #expect(grid.months[0].snapshot == nil)
        #expect(grid.groups.contains { $0.source.isIncome })
    }

    @Test func privateDeficitReviewMatchesAlertAndOpensRealCategoryDetails() throws {
        let snapshot = Self.loaded(try Self.month())
        let sample = BudgetMonthPrivacyProjection.project(snapshot.month)
        let options = BudgetOverspendingPresentation.options(in: sample, isTrackingBudget: true, includeCarryover: true)
        #expect(options.count == BudgetMonthSummaryPresentation.overspentCount(in: sample, includeCarryover: true, isTrackingBudget: true))
        let model = BudgetViewModel(initialMonth: snapshot, initialBudgetID: "demo")
        #expect(model.categoryDetails(for: "food")?.category.budgeted == 60000)
        #expect(model.categoryDetails(for: "missing") == nil)
        #expect(options.allSatisfy { !$0.category.isIncome && $0.category.hidden != true })
    }

    @Test func gridAndAlertsUseTrackingPolicyWithHiddenIncomeAndExpenses() throws {
        let snapshot = Self.loaded(try Self.month())
        let grid = BudgetGridPresentation(visibleMonths: [snapshot.month.month], snapshots: [snapshot.month.month: snapshot],
            privacyEnabled: false, showHidden: false, showTotalAssigned: true, includeCarryover: false, currentMonth: "2026-09")
        #expect(grid.groups.count == 2)
        #expect(grid.months[0].savings?.title == "Saved")
        #expect(grid.months[0].assignedText == nil)
        #expect(grid.months[0].alerts.count == 1)
        #expect(grid.months[0].alerts[0].actionTitle == "Review")
        #expect(grid.months[0].alerts[0].count == 1)
        #expect(!BudgetModePresentation(isTracking: true, isIncome: true).showsBalance)
    }
}
