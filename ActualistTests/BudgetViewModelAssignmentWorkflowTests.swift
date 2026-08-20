import Foundation
import Testing
@testable import Actualist

@MainActor
struct BudgetViewModelAssignmentWorkflowTests {
    @Test func exposesActiveCategoryMonthDetailsForTheAssignmentSheet() throws {
        let model = BudgetViewModel()
        model.selectedMonth = "2026-06"
        model.budgetMonth = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 37_655,
            hiddenCategoryBalance: 0,
            categoryBudgeted: 50_000,
            categorySpent: -12_345,
            lastMonthOverspent: 0
        )
        let category = try #require(model.visibleGroups.first?.visibleCategories.first)

        model.beginAssignmentEditing(for: category)

        let details = try #require(model.activeCategoryMonthDetails)
        #expect(details.category.id == "mortgage")
        #expect(details.month == "2026-06")
        #expect(details.budgetedAmount == 50_000)
        #expect(details.spentAmount == 12_345)
        #expect(details.remainingAmount == 37_655)
    }

    @Test func categoryDetailsOptimisticallySetsCarryoverAndAppliesReloadedCategory() async throws {
        let initialMonth = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: -2_500,
            hiddenCategoryBalance: 0,
            visibleCategoryCarryover: false,
            lastMonthOverspent: 0
        )
        let updatedMonth = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: -2_500,
            hiddenCategoryBalance: 0,
            visibleCategoryCarryover: true,
            lastMonthOverspent: 0
        )
        let initialCategory = try #require(
            initialMonth.categoryGroups.flatMap(\.categories).first { $0.id == "mortgage" }
        )
        let model = CategoryMonthDetailsViewModel(
            details: CategoryMonthDetails(category: initialCategory, month: "2026-06")
        )
        let repository = RecordingBudgetRepository(
            loadedMonth: LoadedBudgetMonth(
                availableMonths: ["2026-06"],
                selectedMonth: "2026-06",
                month: updatedMonth,
                alerts: []
            )
        )

        await model.setCarryover(true, budgetID: "budget", repository: repository)

        #expect(model.isCarryoverEnabled)
        #expect(model.details.category.carryover)
        #expect(!model.isUpdatingCarryover)
        #expect(model.carryoverErrorMessage == nil)

        let update = try await repository.onlyCarryoverUpdate()
        #expect(update.categoryID == "mortgage")
        #expect(update.carryover)
        #expect(update.budgetID == "budget")
        #expect(update.startMonth == "2026-06")
    }

    @Test func categoryDetailsRestoresCarryoverWhenTheWriteFails() async throws {
        let month = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: -2_500,
            hiddenCategoryBalance: 0,
            visibleCategoryCarryover: false,
            lastMonthOverspent: 0
        )
        let category = try #require(
            month.categoryGroups.flatMap(\.categories).first { $0.id == "mortgage" }
        )
        let model = CategoryMonthDetailsViewModel(
            details: CategoryMonthDetails(category: category, month: "2026-06")
        )
        let repository = RecordingBudgetRepository(carryoverError: TestError("rollover failed"))

        await model.setCarryover(true, budgetID: "budget", repository: repository)

        #expect(!model.isCarryoverEnabled)
        #expect(!model.isUpdatingCarryover)
        #expect(model.carryoverErrorMessage == "rollover failed")
    }

    @Test func directAssignmentInputReplacesOriginalAmount() throws {
        let model = BudgetViewModel()

        model.beginAssignmentEditing(for: try BudgetViewModelFixtures.decodeCategory(budgeted: 5_283))
        model.appendAssignmentDigit(5)
        model.appendAssignmentDigit(0)
        model.appendAssignmentDigit(0)

        #expect(model.assignmentDraft?.finalBudgeted == 500)
        #expect(model.assignedAmountDisplay(for: try BudgetViewModelFixtures.decodeCategory(budgeted: 5_283)).primaryText.contains("5.00"))
    }

    @Test func directZeroAssignmentClearsOriginalAmount() throws {
        let model = BudgetViewModel()
        let category = try BudgetViewModelFixtures.decodeCategory(budgeted: 5_283)

        model.beginAssignmentEditing(for: category)
        model.appendAssignmentDigit(0)

        #expect(model.assignmentDraft?.inputDigits == "0")
        #expect(model.assignmentDraft?.finalBudgeted == 0)
        #expect(model.canSubmitAssignment)
        #expect(model.assignedAmountDisplay(for: category).primaryText.contains("0.00"))
    }

    @Test func plusAndMinusAssignmentInputApplyDeltasToOriginalAmount() throws {
        let model = BudgetViewModel()
        let category = try BudgetViewModelFixtures.decodeCategory(budgeted: 5_283)

        model.beginAssignmentEditing(for: category)
        model.setAssignmentInputMode(.subtraction)
        #expect(model.assignmentDraft?.inputMode == .subtraction)
        #expect(model.assignedAmountDisplay(for: category).secondaryText?.hasPrefix("-") == true)

        model.setAssignmentInputMode(.addition)
        model.appendAssignmentDigit(5)
        model.appendAssignmentDigit(0)
        model.appendAssignmentDigit(0)

        #expect(model.assignmentDraft?.finalBudgeted == 5_783)
        #expect(model.assignmentDraft?.signedDelta == 500)
        #expect(model.assignedAmountDisplay(for: category).secondaryText?.contains("5.00") == true)

        model.setAssignmentInputMode(.subtraction)

        #expect(model.assignedAmountDisplay(for: category).secondaryText?.hasPrefix("-") == true)
        #expect(model.assignmentDraft?.finalBudgeted == 4_783)
        #expect(model.assignmentDraft?.signedDelta == -500)
        #expect(model.assignedAmountDisplay(for: category).secondaryText?.contains("-") == true)
    }

    @Test func assignmentInputIsCappedToMaxDigits() throws {
        let model = BudgetViewModel()
        model.beginAssignmentEditing(for: try BudgetViewModelFixtures.decodeCategory(budgeted: 0))

        for _ in 0..<(BudgetViewModel.maxAssignmentDigits + 5) {
            model.appendAssignmentDigit(9)
        }

        let digits = try #require(model.assignmentDraft?.inputDigits)
        #expect(digits.count == BudgetViewModel.maxAssignmentDigits)
        #expect(Int(digits) != nil)
    }

    @Test func assignmentAndAllocationOverflowAreDetected() {
        let assignment = BudgetAssignmentDraft(
            categoryID: "category",
            originalBudgeted: Int.max,
            inputDigits: "1",
            inputMode: .addition
        )
        let allocation = BudgetMoveMoneyDraft(
            focusedCategoryID: "focused",
            focusedCategoryName: "Focused",
            focusedAvailable: 0,
            allocations: [
                BudgetMoveMoneyAllocation(
                    id: "one",
                    destination: .toBudget,
                    amount: Int.max
                ),
                BudgetMoveMoneyAllocation(
                    id: "two",
                    destination: .toBudget,
                    amount: 1
                )
            ]
        )

        #expect(assignment.validatedFinalBudgeted == nil)
        #expect(allocation.validatedTotalAllocatedAmount == nil)
    }

    @Test func assignmentInputSupportsBackspaceClearCancelAndNegativeFinalAmounts() throws {
        let model = BudgetViewModel()
        let category = try BudgetViewModelFixtures.decodeCategory(budgeted: 200)

        model.beginAssignmentEditing(for: category)
        model.setAssignmentInputMode(.subtraction)
        model.appendAssignmentDigit(5)
        model.appendAssignmentDigit(0)
        model.appendAssignmentDigit(0)
        model.deleteAssignmentDigit()

        #expect(model.assignmentDraft?.inputDigits == "50")
        #expect(model.assignmentDraft?.finalBudgeted == 150)

        model.appendAssignmentDigit(0)
        model.appendAssignmentDigit(0)

        #expect(model.assignmentDraft?.finalBudgeted == -4_800)

        model.clearOrCancelAssignmentInput()
        #expect(model.assignmentDraft?.inputDigits == "")

        model.clearOrCancelAssignmentInput()
        #expect(model.assignmentDraft == nil)
    }

    @Test func successfulAssignmentSubmitsFinalAmountAndPreservesExpandedGroupsAfterRefetch() async throws {
        let model = BudgetViewModel()
        let category = try BudgetViewModelFixtures.decodeCategory(budgeted: 5_283)
        let repository = RecordingBudgetRepository(
            loadedMonth: LoadedBudgetMonth(
                availableMonths: ["2026-06"],
                selectedMonth: "2026-06",
                month: try BudgetViewModelFixtures.decodeBudgetMonth(
                    visibleCategoryBalance: 1_000,
                    hiddenCategoryBalance: 0,
                    categoryBudgeted: 5_783,
                    lastMonthOverspent: 0
                ),
                alerts: []
            )
        )

        model.selectedMonth = "2026-06"
        model.expandedGroupIDs = ["bills", "missing"]
        model.beginAssignmentEditing(for: category)
        model.setAssignmentInputMode(.addition)
        model.appendAssignmentDigit(5)
        model.appendAssignmentDigit(0)
        model.appendAssignmentDigit(0)

        let saved = await model.submitAssignment(budgetID: "budget", repository: repository)

        #expect(saved)
        #expect(model.assignmentDraft == nil)
        #expect(model.expandedGroupIDs == ["bills"])

        let assignment = try await repository.onlyAssignment()
        #expect(assignment.categoryID == "gas")
        #expect(assignment.budgeted == 5_783)
        #expect(assignment.month == "2026-06")
        #expect(await repository.didAssignFinished())
    }

    @Test func failedAssignmentKeepsDraftOpenWithInlineError() async throws {
        let model = BudgetViewModel()
        let category = try BudgetViewModelFixtures.decodeCategory(budgeted: 5_283)
        let repository = RecordingBudgetRepository(assignError: TestError("refetch failed"))

        model.selectedMonth = "2026-06"
        model.beginAssignmentEditing(for: category)
        model.appendAssignmentDigit(5)
        model.appendAssignmentDigit(0)
        model.appendAssignmentDigit(0)

        let saved = await model.submitAssignment(budgetID: "budget", repository: repository)

        #expect(saved == false)
        #expect(model.assignmentDraft?.categoryID == "gas")
        #expect(model.activeAssignmentErrorMessage == "refetch failed")
        #expect(model.canSubmitAssignment)
    }

    @Test func successfulMonthTemplateApplySubmitsCommandAndPreservesExpansion() async throws {
        let model = BudgetViewModel()
        let loadedMonth = LoadedBudgetMonth(
            availableMonths: ["2026-06"],
            selectedMonth: "2026-06",
            month: try BudgetViewModelFixtures.decodeBudgetMonth(
                visibleCategoryBalance: 1_000,
                hiddenCategoryBalance: 0,
                lastMonthOverspent: 0
            ),
            alerts: []
        )
        let repository = RecordingBudgetRepository(loadedMonth: loadedMonth)

        model.selectedMonth = "2026-06"
        model.budgetMonth = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 11_220,
            hiddenCategoryBalance: 0,
            lastMonthOverspent: 0
        )
        model.expandedGroupIDs = ["bills", "missing"]

        let applied = await model.applyMonthTemplate(.overwrite, budgetID: "budget", repository: repository)

        #expect(applied)
        #expect(model.monthTemplateSubmissionState == .draft)
        #expect(model.expandedGroupIDs == ["bills"])

        let template = try await repository.onlyTemplate()
        #expect(template.command == .overwrite)
        #expect(template.budgetID == "budget")
        #expect(template.month == "2026-06")
        #expect(await repository.didApplyFinished())
    }

    @Test func successfulCategoryTemplateApplyTargetsActiveCategoryAndClosesKeypad() async throws {
        let model = BudgetViewModel()
        let loadedMonth = LoadedBudgetMonth(
            availableMonths: ["2026-06"],
            selectedMonth: "2026-06",
            month: try BudgetViewModelFixtures.decodeBudgetMonth(
                visibleCategoryBalance: 1_000,
                hiddenCategoryBalance: 0,
                lastMonthOverspent: 0
            ),
            alerts: []
        )
        let category = try BudgetViewModelFixtures.decodeCategory(budgeted: 5_283)
        let repository = RecordingBudgetRepository(loadedMonth: loadedMonth)

        model.selectedMonth = "2026-06"
        model.beginAssignmentEditing(for: category)

        let applied = await model.applyCategoryTemplate(budgetID: "budget", repository: repository)

        #expect(applied)
        #expect(model.assignmentDraft == nil)

        let template = try await repository.onlyTemplate()
        #expect(template.command == .category("gas"))
        #expect(template.month == "2026-06")
        #expect(await repository.didApplyFinished())
    }
}
