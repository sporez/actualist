import Testing
import Foundation
@testable import Actualist

@MainActor
struct BudgetViewportModelStateTests {
    @Test func resizeReversalKeepsExistingValuesAndDiscardsLateMonth() async {
        let repository = BudgetViewportTestRepository()
        for month in ["2026-07", "2026-08", "2026-09"] {
            await repository.set(BudgetViewportFixtures.loaded(month))
        }
        let model = BudgetViewportModel(repository: repository)
        await model.load(budgetID: "budget", anchorMonth: "2026-07")
        await repository.block("2026-09")
        model.setResolvedMonthCount(3)
        let growth = Task { await model.refreshVisibleMonths() }
        await repository.waitUntilReadBlocked("2026-09")
        #expect(model.visibleMonths.count == 3)
        #expect(model.snapshot(for: "2026-07")?.month.totalBudgeted == 100)
        #expect(model.snapshot(for: "2026-09") == nil)
        model.setResolvedMonthCount(1)
        #expect(await model.refreshVisibleMonths())
        await repository.release("2026-09")
        #expect(await growth.value == false)
        #expect(model.visibleMonths == ["2026-07"])
        #expect(Set(model.monthSnapshots.keys) == ["2026-07"])
        #expect(model.monthErrors.isEmpty)
        #expect(!model.isLoading)
    }

    @Test func disappearingAssignmentAnchorRetainsDraftAndCapturedMonth() async {
        let repository = BudgetViewportTestRepository()
        for month in ["2026-07", "2026-08"] { await repository.set(BudgetViewportFixtures.loaded(month)) }
        let model = BudgetViewportModel(repository: repository)
        model.setResolvedMonthCount(2)
        await model.load(budgetID: "budget", anchorMonth: "2026-07")
        model.beginAssignmentEditing(categoryID: "groceries", month: "2026-08")
        model.appendKeypadDigit(7)
        model.setResolvedMonthCount(1)
        #expect(model.assignmentPresentationCell?.month == "2026-07")
        #expect(model.selectedCell?.month == "2026-08")
        #expect(model.assignmentWorkflow.draft?.inputDigits == "7")
        #expect(await model.refreshVisibleMonths())
        #expect(model.snapshot(for: "2026-08") != nil)
        model.setResolvedMonthCount(2)
        #expect(model.assignmentPresentationCell == model.selectedCell)
        model.setResolvedMonthCount(1)
        #expect(await model.submitAssignment())
        model.setResolvedMonthCount(2)
        #expect(await model.refreshVisibleMonths())
        #expect(model.snapshot(for: "2026-08")?.month.totalBudgeted == 7)
        #expect(model.snapshot(for: "2026-07")?.month.totalBudgeted == 100)
        #expect(model.assignmentPresentationCell == nil)
    }

    @Test func newestNavigationWinsAndOldReadCannotReplaceIt() async {
        let repository = BudgetViewportTestRepository()
        await repository.set(BudgetViewportFixtures.loaded("2026-07"))
        await repository.set(BudgetViewportFixtures.loaded("2026-08"))
        let model = BudgetViewportModel(repository: repository)
        await model.load(budgetID: "budget", anchorMonth: "2026-07")
        await repository.block("2026-07")
        let old = Task { await model.load(budgetID: "budget", anchorMonth: "2026-07") }
        await repository.waitUntilReadBlocked("2026-07")
        await model.load(budgetID: "budget", anchorMonth: "2026-08")
        await repository.release("2026-07")
        await old.value
        #expect(model.anchorMonth == "2026-08")
    }

    @Test func hiddenCategoryClearsInspectorAndEditingSelection() async {
        let repository = BudgetViewportTestRepository()
        await repository.set(BudgetViewportFixtures.loaded("2026-07"))
        let model = BudgetViewportModel(repository: repository)
        await model.load(budgetID: "budget", anchorMonth: "2026-07")
        model.selectCategory(categoryID: "groceries", month: "2026-07")
        model.beginAssignmentEditing(categoryID: "groceries", month: "2026-07")
        await repository.set(BudgetViewportFixtures.loaded("2026-07", hidden: true))
        await model.refreshVisibleMonths()
        #expect(model.inspectedCell == nil)
        #expect(model.selectedCell == nil)
    }
    @Test func partialMonthErrorIsVisibleThenClearsOnRetry() async {
        let repository = BudgetViewportTestRepository()
        await repository.set(BudgetViewportFixtures.loaded("2026-07"))
        await repository.set(BudgetViewportFixtures.loaded("2026-08"))
        await repository.setError(ViewportTestError.missingMonth("temporary"), for: "2026-08")
        let model = BudgetViewportModel(repository: repository)
        model.setResolvedMonthCount(2)
        await model.load(budgetID: "budget", anchorMonth: "2026-07")
        #expect(model.monthErrors["2026-08"] != nil)
        await repository.setError(nil, for: "2026-08")
        #expect(await model.refreshVisibleMonths())
        #expect(model.monthErrors["2026-08"] == nil)
        #expect(model.snapshot(for: "2026-08")?.month.month == "2026-08")
    }

    @Test func budgetSwitchDuringWriteCannotEraseReplacementDraft() async {
        let repository = BudgetViewportTestRepository()
        await repository.set(BudgetViewportFixtures.loaded("2026-07"))
        let model = BudgetViewportModel(repository: repository)
        await model.load(budgetID: "old", anchorMonth: "2026-07")
        model.beginAssignmentEditing(categoryID: "groceries", month: "2026-07")
        model.appendKeypadDigit(7)
        await repository.blockAssignment()
        let save = Task { await model.submitAssignment() }
        await repository.waitUntilAssignmentBlocked()
        await model.load(budgetID: "new", anchorMonth: "2026-07")
        model.beginAssignmentEditing(categoryID: "groceries", month: "2026-07")
        model.appendKeypadDigit(9)
        await repository.releaseAssignment()
        #expect(await save.value == false)
        #expect(model.budgetID == "new")
        #expect(model.assignmentWorkflow.draft?.inputDigits == "9")
    }

    @Test func refreshDuringWriteDoesNotDiscardSuccessfulCommit() async {
        let repository = BudgetViewportTestRepository()
        await repository.set(BudgetViewportFixtures.loaded("2026-07"))
        let model = BudgetViewportModel(repository: repository)
        await model.load(budgetID: "budget", anchorMonth: "2026-07")
        model.beginAssignmentEditing(categoryID: "groceries", month: "2026-07")
        model.appendKeypadDigit(7)
        await repository.blockAssignment()
        let save = Task { await model.submitAssignment() }
        await repository.waitUntilAssignmentBlocked()
        await model.refreshVisibleMonths()
        await repository.releaseAssignment()
        #expect(await save.value)
        #expect(model.snapshot(for: "2026-07")?.month.totalBudgeted == 7)
        #expect(model.selectedCell == nil)
    }

    @Test func inspectorMonthStaysFreshAfterVisibleRangeShrinks() async {
        let repository = BudgetViewportTestRepository()
        for month in ["2026-07", "2026-08"] { await repository.set(BudgetViewportFixtures.loaded(month)) }
        let model = BudgetViewportModel(repository: repository)
        model.setResolvedMonthCount(2)
        await model.load(budgetID: "budget", anchorMonth: "2026-07")
        model.selectCategory(categoryID: "groceries", month: "2026-08")
        model.setResolvedMonthCount(1)
        await repository.set(BudgetViewportFixtures.loaded("2026-08", budgeted: 900))
        await model.refreshVisibleMonths()
        #expect(model.selectedCategoryDetails?.month == "2026-08")
        #expect(model.selectedCategoryDetails?.category.budgeted == 900)
        #expect(model.visibleMonths == ["2026-07"])
        model.closeInspector()
        #expect(model.anchorMonth == "2026-07")
    }

    @Test func collapseAllSurvivesRefreshAndBlankTabMovesWithinVisibleMonths() async {
        let repository = BudgetViewportTestRepository()
        for month in ["2026-07", "2026-08"] { await repository.set(BudgetViewportFixtures.loaded(month)) }
        let model = BudgetViewportModel(repository: repository)
        model.setResolvedMonthCount(2)
        await model.load(budgetID: "budget", anchorMonth: "2026-07")
        model.toggleGroup(id: "group")
        await model.refreshVisibleMonths()
        #expect(model.expandedGroupIDs.isEmpty)
        model.toggleGroup(id: "group")
        model.beginAssignmentEditing(categoryID: "groceries", month: "2026-07")
        #expect(await model.handleHardwareInput("\t"))
        #expect(model.selectedCell?.month == "2026-08")
        #expect(await model.handleHardwareInput("\u{19}"))
        #expect(model.selectedCell?.month == "2026-07")
        #expect(model.assignmentWorkflow.draft?.inputDigits == "")
    }

    @Test func cancelledLoadCanRetryAndTwoWindowsKeepSeparateAnchors() async {
        let repository = BudgetViewportTestRepository()
        for month in ["2026-07", "2026-08"] { await repository.set(BudgetViewportFixtures.loaded(month)) }
        let first = BudgetViewportModel(repository: repository)
        let second = BudgetViewportModel(repository: repository)
        await repository.block("2026-07")
        let load = Task { await first.load(budgetID: "budget", anchorMonth: "2026-07") }
        await repository.waitUntilReadBlocked("2026-07")
        load.cancel()
        await repository.release("2026-07")
        await load.value
        #expect(!first.isLoading)
        await first.load(budgetID: "budget", anchorMonth: "2026-07")
        await second.load(budgetID: "budget", anchorMonth: "2026-08")
        #expect(first.anchorMonth == "2026-07")
        #expect(second.anchorMonth == "2026-08")
        #expect(first.errorMessage == nil)
    }

    @Test func unresolvedInitialLoadRefreshRetriesAndReportsTruthfully() async {
        let currentMonth = YearMonth(date: Date()).rawValue
        let repository = BudgetViewportTestRepository()
        let model = BudgetViewportModel(repository: repository)
        await repository.setCurrentReadError(ViewportTestError.missingMonth("offline"))
        await model.load(budgetID: "budget")
        #expect(model.anchorMonth == nil)
        #expect(await model.refreshVisibleMonths() == false)
        #expect(model.errorMessage != nil)
        await repository.set(BudgetViewportFixtures.loaded(currentMonth))
        await repository.setCurrentReadError(nil)
        #expect(await model.refreshVisibleMonths())
        #expect(model.anchorMonth == currentMonth)
        #expect(model.snapshot(for: currentMonth) != nil)
    }
}
