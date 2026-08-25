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
        #expect(model.moveMoneySliderSpec().detentAmount == 11_220)
        #expect(
            model.moveMoneyMaximumAmount
                == BudgetMoveMoneySliderMetrics.maximumAmount(baselineAmount: 11_220, currentAmount: 0)
        )

        model.setMoveMoneyAmountDollars(120)
        #expect(model.moveMoneyDraft?.amount == 12_000)

        model.setMoveMoneyAmountDollars(-5)
        #expect(model.moveMoneyDraft?.amount == 0)
    }

    @Test func moveMoneyForOverspentCategoryDefaultsToCoverAmountIntoFocusedCategory() async throws {
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
        #expect(model.moveMoneyDraft?.amount == 0)
        #expect(model.hasPendingMoveMoneyCoverIntro)
        await finishCoverIntro(model)
        #expect(model.moveMoneyDraft?.amount == 0)
        #expect(model.hasPendingMoveMoneyCoverIntro)

        model.selectMoveMoneyDestination(.category(id: "utilities", name: "🧹 Utilities"))
        await finishCoverIntro(model)
        #expect(model.moveMoneyDraft?.amount == 7_693)
        #expect(abs(model.moveMoneyAmountDollars - 76.93) < 0.001)
        #expect(model.moveMoneySliderDetentFeedback == 1)
        #expect(model.moveMoneySliderSpec().detentAmount == 12_000)
        #expect(
            model.moveMoneyMaximumAmount
                == BudgetMoveMoneySliderMetrics.maximumAmount(baselineAmount: 12_000, currentAmount: 7_693)
        )
        #expect(model.canSubmitMoveMoney)
        #expect(model.moveMoneyAvailableDisplayAmount == 0)
        #expect(model.moveMoneyCounterpartyAvailableDisplayAmount == 4_307)
    }

    @Test func overspentAlertCategoryTapStartsCoverMoveMoneyDraft() async throws {
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
        #expect(option.amountText(using: model.currency).contains("76.93"))
        #expect(model.assignmentDraft == nil)
        #expect(model.moveMoneyDraft?.focusedCategoryID == option.id)
        #expect(model.moveMoneyDraft?.direction == .intoFocusedCategory)
        #expect(model.moveMoneyDraft?.amount == 0)
        await finishCoverIntro(model)
        #expect(model.moveMoneyDraft?.amount == 0)
    }

    @Test func moveMoneyCoverAmountDoesNotClampToSelectedSourceAvailability() async throws {
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
        await finishCoverIntro(model)

        #expect(model.moveMoneyDraft?.amount == 7_693)
        #expect(model.moveMoneySliderSpec().detentAmount == 5_000)
        #expect(
            model.moveMoneyMaximumAmount
                == BudgetMoveMoneySliderMetrics.maximumAmount(baselineAmount: 5_000, currentAmount: 7_693)
        )
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
        #expect(model.moveMoneySliderSpec().detentAmount == 12_000)
        #expect(
            model.moveMoneyMaximumAmount
                == BudgetMoveMoneySliderMetrics.maximumAmount(baselineAmount: 12_000, currentAmount: 2_500)
        )
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

    @Test func moveMoneySliderHoldsAtAvailableThenAllowsOvershootOnNextGesture() throws {
        let model = try makeMoveMoneyModel(visibleCategoryBalance: 11_220)

        model.setMoveMoneySliderEditing(true)
        model.setMoveMoneySliderAmountDollars(50)
        #expect(model.moveMoneyDraft?.amount == 5_000)
        #expect(model.moveMoneySliderDetentFeedback == 0)

        model.setMoveMoneySliderAmountDollars(130)
        #expect(model.moveMoneyDraft?.amount == 11_220)
        #expect(model.moveMoneySliderDetentFeedback == 1)

        model.setMoveMoneySliderAmountDollars(140)
        #expect(model.moveMoneyDraft?.amount == 11_220)
        #expect(model.moveMoneySliderDetentFeedback == 1)

        model.setMoveMoneySliderEditing(false)
        model.setMoveMoneySliderEditing(true)
        model.setMoveMoneySliderAmountDollars(130)
        #expect(model.moveMoneyDraft?.amount == 13_000)
        #expect(model.moveMoneySliderDetentFeedback == 1)
        #expect(model.moveMoneySliderSpec().isOvershooting)
    }

    @Test func moveMoneySliderKeepsDetentWhenFingerLiftsPastAvailable() throws {
        let model = try makeMoveMoneyModel(visibleCategoryBalance: 11_220)

        model.setMoveMoneySliderEditing(true)
        model.setMoveMoneySliderAmountDollars(130)
        #expect(model.moveMoneyDraft?.amount == 11_220)

        model.setMoveMoneySliderEditing(false)
        model.setMoveMoneySliderAmountDollars(model.moveMoneyMaximumDollars)
        #expect(model.moveMoneyDraft?.amount == 11_220)
        #expect(model.moveMoneySliderDetentFeedback == 1)
    }

    @Test func moveMoneySliderDoesNotExplodeWhenThumbStaysAtMaximum() throws {
        let model = try makeMoveMoneyModel(visibleCategoryBalance: 11_220)
        let scaledAvailable = BudgetMoveMoneySliderMetrics.maximumAmount(
            baselineAmount: 11_220,
            currentAmount: 0
        )

        model.setMoveMoneySliderEditing(true)
        model.setMoveMoneySliderAmountDollars(130)
        model.setMoveMoneySliderEditing(false)
        model.setMoveMoneySliderEditing(true)

        for _ in 0..<40 {
            model.setMoveMoneySliderAmountDollars(model.moveMoneyMaximumDollars)
        }

        #expect(model.moveMoneyDraft?.amount == scaledAvailable)
        #expect(model.moveMoneyMaximumAmount == scaledAvailable)
    }

    @Test func moveMoneyKeypadDoesNotTriggerSliderDetent() throws {
        let model = try makeMoveMoneyModel(visibleCategoryBalance: 11_220)

        model.setMoveMoneyAmountDollars(130)
        #expect(model.moveMoneyDraft?.amount == 13_000)
        #expect(model.moveMoneySliderDetentFeedback == 0)
        #expect(model.moveMoneySliderSpec().isOvershooting)
    }

    @Test func moveMoneySliderHasNoDetentWhenSourceIsAlreadyNegative() throws {
        let model = try makeMoveMoneyModel(visibleCategoryBalance: -7_693)

        #expect(model.moveMoneyDraft?.direction == .intoFocusedCategory)
        #expect(model.moveMoneySliderSpec().detentAmount == 0)

        model.setMoveMoneySliderEditing(true)
        model.setMoveMoneySliderAmountDollars(20)
        #expect(model.moveMoneyDraft?.amount == 2_000)
        #expect(model.moveMoneySliderDetentFeedback == 0)
    }

    @Test func splitMoveMoneySliderDetentUsesRemainingSourceAvailable() throws {
        let model = try makeMoveMoneyModel(visibleCategoryBalance: 10_000)

        model.toggleMoveMoneyDestination(.category(id: "utilities", name: "🧹 Utilities"))
        model.toggleMoveMoneyDestination(.toBudget)
        model.setFocusedMoveMoneyAllocation("utilities")
        model.setMoveMoneyAmountDollars(60)

        let remaining = model.moveMoneySliderSpec(for: "to-budget")
        #expect(remaining.detentAmount == 4_000)
        #expect(
            remaining.maximumAmount
                == BudgetMoveMoneySliderMetrics.maximumAmount(baselineAmount: 4_000, currentAmount: 0)
        )

        model.setMoveMoneySliderEditing(true, allocationID: "to-budget")
        model.setMoveMoneySliderAmountDollars(80, allocationID: "to-budget")
        #expect(model.moveMoneyDraft?.allocations.first(where: { $0.id == "to-budget" })?.amount == 4_000)
        #expect(model.moveMoneySliderDetentFeedback == 1)
    }

    @Test func overspentCoverIntroStartsAtZeroAndLandsOnCoverAmount() async throws {
        let model = try makeMoveMoneyModel(visibleCategoryBalance: -7_693)

        #expect(model.moveMoneyDraft?.amount == 0)
        #expect(model.hasPendingMoveMoneyCoverIntro)
        #expect(model.moveMoneySliderDetentFeedback == 0)

        await finishCoverIntro(model)
        #expect(model.moveMoneyDraft?.amount == 0)
        #expect(model.hasPendingMoveMoneyCoverIntro)

        model.selectMoveMoneyDestination(.category(id: "utilities", name: "🧹 Utilities"))
        await finishCoverIntro(model)

        #expect(model.moveMoneyDraft?.amount == 7_693)
        #expect(model.hasPendingMoveMoneyCoverIntro == false)
        #expect(model.moveMoneySliderDetentFeedback == 1)
        #expect(model.moveMoneyAvailableDisplayAmount == 0)
    }

    @Test func grabbingTheSliderCancelsTheOverspentCoverIntro() async throws {
        let model = try makeMoveMoneyModel(visibleCategoryBalance: -7_693)
        model.selectMoveMoneyDestination(.category(id: "utilities", name: "🧹 Utilities"))

        await model.moveMoneyWorkflow.playCoverIntro { _ in
            await MainActor.run {
                if (model.moveMoneyDraft?.amount ?? 0) > 0 {
                    model.setMoveMoneySliderEditing(true)
                }
            }
        }

        let amount = try #require(model.moveMoneyDraft?.amount)
        #expect(amount > 0)
        #expect(amount < 7_693)
        #expect(model.moveMoneySliderDetentFeedback == 0)
        #expect(model.hasPendingMoveMoneyCoverIntro == false)
    }

    private func finishCoverIntro(_ model: BudgetViewModel) async {
        await model.moveMoneyWorkflow.playCoverIntro(sleep: { _ in })
    }

    private func makeMoveMoneyModel(visibleCategoryBalance: Int) throws -> BudgetViewModel {
        let model = BudgetViewModel()
        let month = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: visibleCategoryBalance,
            hiddenCategoryBalance: 0,
            lastMonthOverspent: 0
        )
        model.budgetMonth = month
        let category = try #require(month.categoryGroups.first(where: { !$0.isIncome })?.visibleCategories.first)
        model.beginAssignmentEditing(for: category)
        model.beginMoveMoney()
        return model
    }
}
