import Foundation
import Testing
@testable import Actualist

@MainActor
struct BudgetViewModelMoveMoneyWorkflowTests {
    @Test func moveMoneyForPositiveCategoryAllowsAmountsPastAvailableBalance() throws {
        let model = BudgetViewModel()
        let month = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 11_220,
            hiddenCategoryBalance: 0,
            lastMonthOverspent: 0
        )
        model.budgetMonth = month

        let category = try #require(month.categoryGroups.first(where: { !$0.isIncome })?.visibleCategories.first)
        model.beginAssignmentEditing(for: category)
        model.beginMoveMoney()

        #expect(model.moveMoneyDraft?.amount == 0)
        #expect(model.moveMoneyDraft?.direction == .outOfFocusedCategory)
        #expect(model.moveMoneyMaximumDollars == 1000)

        model.setMoveMoneyAmountDollars(120)
        #expect(model.moveMoneyDraft?.amount == 12_000)

        model.setMoveMoneyAmountDollars(-5)
        #expect(model.moveMoneyDraft?.amount == 0)
    }

    @Test func moveMoneyForOverspentCategoryDefaultsToCoverAmountIntoFocusedCategory() throws {
        let model = BudgetViewModel()
        let month = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: -7_693,
            hiddenCategoryBalance: 0,
            counterpartyCategoryBalance: 12_000,
            lastMonthOverspent: 0
        )
        model.budgetMonth = month

        let category = try #require(month.categoryGroups.first(where: { !$0.isIncome })?.visibleCategories.first)
        model.beginAssignmentEditing(for: category)
        model.beginMoveMoney()

        #expect(model.moveMoneyDraft?.direction == .intoFocusedCategory)
        #expect(model.moveMoneyDraft?.amount == 7_693)
        #expect(abs(model.moveMoneyAmountDollars - 76.93) < 0.001)
        #expect(model.moveMoneyMaximumDollars == 1000)
        #expect(model.canSubmitMoveMoney == false)

        model.selectMoveMoneyDestination(.category(id: "utilities", name: "🧹 Utilities"))

        #expect(model.moveMoneyDraft?.amount == 7_693)
        #expect(model.moveMoneyMaximumDollars == 1000)
        #expect(model.canSubmitMoveMoney)
        #expect(model.moveMoneyAvailableDisplayAmount == 0)
        #expect(model.moveMoneyCounterpartyAvailableDisplayAmount == 4_307)
    }

    @Test func overspentAlertCategoryTapStartsCoverMoveMoneyDraft() throws {
        let model = BudgetViewModel()
        let month = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: -7_693,
            hiddenCategoryBalance: 0,
            counterpartyCategoryBalance: 12_000,
            lastMonthOverspent: 0
        )
        model.budgetMonth = month

        let option = try #require(model.overspentCategoryOptions.first)
        model.beginMoveMoney(for: option.id)

        #expect(option.categoryName == "Mortgage")
        #expect(option.amountText.contains("76.93"))
        #expect(model.assignmentDraft == nil)
        #expect(model.moveMoneyDraft?.focusedCategoryID == option.id)
        #expect(model.moveMoneyDraft?.direction == .intoFocusedCategory)
        #expect(model.moveMoneyDraft?.amount == 7_693)
    }

    @Test func moveMoneyCoverAmountDoesNotClampToSelectedSourceAvailability() throws {
        let model = BudgetViewModel()
        let month = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: -7_693,
            hiddenCategoryBalance: 0,
            counterpartyCategoryBalance: 5_000,
            lastMonthOverspent: 0
        )
        model.budgetMonth = month

        let category = try #require(month.categoryGroups.first(where: { !$0.isIncome })?.visibleCategories.first)
        model.beginAssignmentEditing(for: category)
        model.beginMoveMoney()
        model.selectMoveMoneyDestination(.category(id: "utilities", name: "🧹 Utilities"))

        #expect(model.moveMoneyDraft?.amount == 7_693)
        #expect(model.moveMoneyMaximumDollars == 1000)
    }

    @Test func moveMoneyDestinationOptionsUseToBudgetAndExcludeSourceCategory() throws {
        let model = BudgetViewModel()
        let month = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 11_220,
            hiddenCategoryBalance: 0,
            lastMonthOverspent: 0
        )
        model.budgetMonth = month

        let category = try #require(month.categoryGroups.first(where: { !$0.isIncome })?.visibleCategories.first)
        model.beginAssignmentEditing(for: category)
        model.beginMoveMoney()

        #expect(model.toBudgetDestinationOption().title == "To Budget")
        #expect(model.moveMoneyDestinationGroups(matching: "").flatMap(\.options).contains(where: { $0.id == category.id }) == false)
    }

    @Test func moveMoneyCounterpartyBalanceUsesSelectedCategoryAmount() throws {
        let model = BudgetViewModel()
        let month = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 11_220,
            hiddenCategoryBalance: 0,
            counterpartyCategoryBalance: 5_000,
            lastMonthOverspent: 0
        )
        model.budgetMonth = month

        let category = try #require(month.categoryGroups.first(where: { !$0.isIncome })?.visibleCategories.first)
        model.beginAssignmentEditing(for: category)
        model.beginMoveMoney()
        model.selectMoveMoneyDestination(.category(id: "utilities", name: "🧹 Utilities"))
        model.setMoveMoneyAmountDollars(25)

        #expect(model.moveMoneyAvailableDisplayAmount == 8_720)
        #expect(model.moveMoneyCounterpartyAvailableDisplayAmount == 7_500)
    }

    @Test func successfulMoveMoneyToBudgetSubmitsNilDestinationAndClearsEditingState() async throws {
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

        let category = try #require(model.budgetMonth?.categoryGroups.first(where: { !$0.isIncome })?.visibleCategories.first)
        model.beginAssignmentEditing(for: category)
        model.beginMoveMoney()
        model.setMoveMoneyAmountDollars(25)
        model.selectMoveMoneyDestination(.toBudget)

        let saved = await model.submitMoveMoney(budgetID: "budget", repository: repository)

        #expect(saved)
        #expect(model.moveMoneyDraft == nil)
        #expect(model.assignmentDraft == nil)
        #expect(model.expandedGroupIDs == ["bills"])

        let move = try await repository.onlyMove()
        #expect(move.command == BudgetMoveMoneyCommand(
            fromCategoryID: "mortgage",
            toCategoryID: nil,
            amount: 2_500
        ))
        #expect(move.month == "2026-06")
        #expect(await repository.didMoveFinished())
    }

    @Test func moveMoneyDirectionToggleMovesFromSelectedCategoryIntoFocusedCategory() async throws {
        let model = BudgetViewModel()
        let repository = RecordingBudgetRepository()

        model.selectedMonth = "2026-06"
        model.budgetMonth = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 7_693,
            hiddenCategoryBalance: 0,
            counterpartyCategoryBalance: 12_000,
            lastMonthOverspent: 0
        )

        let category = try #require(model.budgetMonth?.categoryGroups.first(where: { !$0.isIncome })?.visibleCategories.first)
        model.beginAssignmentEditing(for: category)
        model.beginMoveMoney()
        model.toggleMoveMoneyDirection()
        model.selectMoveMoneyDestination(.category(id: "utilities", name: "🧹 Utilities"))
        model.setMoveMoneyAmountDollars(25)

        #expect(model.moveMoneyDraft?.direction == .intoFocusedCategory)
        #expect(model.moveMoneyMaximumDollars == 1000)
        #expect(model.moveMoneyAvailableDisplayAmount == 10_193)
        #expect(model.moveMoneyCounterpartyAvailableDisplayAmount == 9_500)

        let saved = await model.submitMoveMoney(budgetID: "budget", repository: repository)

        #expect(saved)
        let move = try await repository.onlyMove()
        #expect(move.command == BudgetMoveMoneyCommand(
            fromCategoryID: "utilities",
            toCategoryID: "mortgage",
            amount: 2_500
        ))
    }

    @Test func multiDestinationMoveMoneyBuildsOneCommandPerAllocation() async throws {
        let model = BudgetViewModel()
        let repository = RecordingBudgetRepository()

        model.selectedMonth = "2026-06"
        model.budgetMonth = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 10_000,
            hiddenCategoryBalance: 0,
            counterpartyCategoryBalance: 1_000,
            lastMonthOverspent: 0
        )

        let category = try #require(model.budgetMonth?.categoryGroups.first(where: { !$0.isIncome })?.visibleCategories.first)
        model.beginAssignmentEditing(for: category)
        model.beginMoveMoney()
        model.toggleMoveMoneyDestination(.category(id: "utilities", name: "🧹 Utilities"))
        model.setFocusedMoveMoneyAllocation("utilities")
        model.setMoveMoneyAmountDollars(249.29)
        model.toggleMoveMoneyDestination(.toBudget)
        model.setFocusedMoveMoneyAllocation("to-budget")
        model.setMoveMoneyAmountDollars(100)

        #expect(model.moveMoneyDisplayAmount == 34_929)
        #expect(model.moveMoneyAvailableDisplayAmount == -24_929)

        let saved = await model.submitMoveMoney(budgetID: "budget", repository: repository)

        #expect(saved)
        let moves = await repository.recordedMoves()
        #expect(moves.map(\.command) == [
            BudgetMoveMoneyCommand(fromCategoryID: "mortgage", toCategoryID: "utilities", amount: 24_929),
            BudgetMoveMoneyCommand(fromCategoryID: "mortgage", toCategoryID: nil, amount: 10_000)
        ])
    }

    @Test func moveMoneyKeypadDigitsApplyToFocusedAllocation() async throws {
        let model = BudgetViewModel()
        model.selectedMonth = "2026-06"
        model.budgetMonth = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 10_000,
            hiddenCategoryBalance: 0,
            counterpartyCategoryBalance: 1_000,
            lastMonthOverspent: 0
        )

        let category = try #require(model.budgetMonth?.categoryGroups.first(where: { !$0.isIncome })?.visibleCategories.first)
        model.beginAssignmentEditing(for: category)
        model.beginMoveMoney()
        model.toggleMoveMoneyDestination(.category(id: "utilities", name: "🧹 Utilities"))
        model.toggleMoveMoneyDestination(.toBudget)

        model.setFocusedMoveMoneyAllocation("utilities")
        model.appendMoveMoneyDigit(1)
        model.appendMoveMoneyDigit(2)
        model.appendMoveMoneyDigit(3)

        #expect(model.moveMoneyDraft?.allocations.first(where: { $0.id == "utilities" })?.amount == 123)
        #expect(model.moveMoneyDraft?.allocations.first(where: { $0.id == "to-budget" })?.amount == 0)

        model.setFocusedMoveMoneyAllocation("to-budget")
        model.appendMoveMoneyDigit(4)

        #expect(model.moveMoneyDraft?.allocations.first(where: { $0.id == "utilities" })?.amount == 123)
        #expect(model.moveMoneyDraft?.allocations.first(where: { $0.id == "to-budget" })?.amount == 4)
    }

    @Test func failedMoveMoneyKeepsDraftOpenWithInlineError() async throws {
        let model = BudgetViewModel()
        let repository = RecordingBudgetRepository(moveError: TestError("transfer failed"))

        model.selectedMonth = "2026-06"
        model.budgetMonth = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 11_220,
            hiddenCategoryBalance: 0,
            lastMonthOverspent: 0
        )

        let category = try #require(model.budgetMonth?.categoryGroups.first(where: { !$0.isIncome })?.visibleCategories.first)
        model.beginAssignmentEditing(for: category)
        model.beginMoveMoney()
        model.setMoveMoneyAmountDollars(25)
        model.selectMoveMoneyDestination(.category(id: "gas", name: "Gas"))

        let saved = await model.submitMoveMoney(budgetID: "budget", repository: repository)

        #expect(saved == false)
        #expect(model.moveMoneyDraft?.focusedCategoryID == "mortgage")
        #expect(model.activeMoveMoneyErrorMessage == "transfer failed")
        #expect(model.canSubmitMoveMoney)
    }
}
