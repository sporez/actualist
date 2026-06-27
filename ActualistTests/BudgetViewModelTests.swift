import Foundation
import Testing
@testable import Actualist

@MainActor
struct BudgetViewModelTests {
    @Test func derivesVisibleGroupsAndOverspendingCount() throws {
        let model = BudgetViewModel()
        model.budgetMonth = try Self.decodeBudgetMonth(
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
        model.budgetMonth = try Self.decodeBudgetMonth(
            visibleCategoryBalance: 1000,
            hiddenCategoryBalance: -5000,
            toBudget: 0,
            lastMonthOverspent: -1000
        )

        #expect(model.overspendingAlertCount == 1)
    }

    @Test func buildsReusableBudgetAlertsFromAPIPayloads() throws {
        let alerts = [
            BudgetAlert(
                apiAlert: APIBudgetMonthAlert(
                    kind: "toBudget",
                    severity: "positive",
                    title: "To Budget",
                    amount: 1500,
                    count: nil,
                    actionTitle: nil
                )
            ),
            BudgetAlert(
                apiAlert: APIBudgetMonthAlert(
                    kind: "overspending",
                    severity: "danger",
                    title: "Overspent categories",
                    amount: nil,
                    count: 1,
                    actionTitle: "Cover"
                )
            ),
            BudgetAlert(
                apiAlert: APIBudgetMonthAlert(
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

    @Test func ignoresUnknownAPIAlertKinds() {
        let alert = BudgetAlert(
            apiAlert: APIBudgetMonthAlert(
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

    @Test func omitsZeroToBudgetAlert() throws {
        let model = BudgetViewModel()
        model.budgetMonth = try Self.decodeBudgetMonth(
            visibleCategoryBalance: 1000,
            hiddenCategoryBalance: 0,
            toBudget: 0,
            lastMonthOverspent: 0
        )

        #expect(model.budgetAlerts.isEmpty)
    }

    @Test func directAssignmentInputReplacesOriginalAmount() throws {
        let model = BudgetViewModel()

        model.beginAssignmentEditing(for: try Self.decodeCategory(budgeted: 5_283))
        model.appendAssignmentDigit(5)
        model.appendAssignmentDigit(0)
        model.appendAssignmentDigit(0)

        #expect(model.assignmentDraft?.finalBudgeted == 500)
        #expect(model.assignedAmountDisplay(for: try Self.decodeCategory(budgeted: 5_283)).primaryText.contains("5.00"))
    }

    @Test func directZeroAssignmentClearsOriginalAmount() throws {
        let model = BudgetViewModel()
        let category = try Self.decodeCategory(budgeted: 5_283)

        model.beginAssignmentEditing(for: category)
        model.appendAssignmentDigit(0)

        #expect(model.assignmentDraft?.inputDigits == "0")
        #expect(model.assignmentDraft?.finalBudgeted == 0)
        #expect(model.canSubmitAssignment)
        #expect(model.assignedAmountDisplay(for: category).primaryText.contains("0.00"))
    }

    @Test func plusAndMinusAssignmentInputApplyDeltasToOriginalAmount() throws {
        let model = BudgetViewModel()
        let category = try Self.decodeCategory(budgeted: 5_283)

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
        model.beginAssignmentEditing(for: try Self.decodeCategory(budgeted: 0))

        for _ in 0..<(BudgetViewModel.maxAssignmentDigits + 5) {
            model.appendAssignmentDigit(9)
        }

        let digits = try #require(model.assignmentDraft?.inputDigits)
        #expect(digits.count == BudgetViewModel.maxAssignmentDigits)
        #expect(Int(digits) != nil)
    }

    @Test func assignmentInputSupportsBackspaceClearCancelAndNegativeFinalAmounts() throws {
        let model = BudgetViewModel()
        let category = try Self.decodeCategory(budgeted: 200)

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
        let category = try Self.decodeCategory(budgeted: 5_283)
        let repository = RecordingBudgetRepository(
            loadedMonth: LoadedBudgetMonth(
                availableMonths: ["2026-06"],
                selectedMonth: "2026-06",
                month: try Self.decodeBudgetMonth(
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
        let category = try Self.decodeCategory(budgeted: 5_283)
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
            month: try Self.decodeBudgetMonth(
                visibleCategoryBalance: 1_000,
                hiddenCategoryBalance: 0,
                lastMonthOverspent: 0
            ),
            alerts: []
        )
        let repository = RecordingBudgetRepository(loadedMonth: loadedMonth)

        model.selectedMonth = "2026-06"
        model.budgetMonth = try Self.decodeBudgetMonth(
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
            month: try Self.decodeBudgetMonth(
                visibleCategoryBalance: 1_000,
                hiddenCategoryBalance: 0,
                lastMonthOverspent: 0
            ),
            alerts: []
        )
        let category = try Self.decodeCategory(budgeted: 5_283)
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

    @Test func moveMoneyForPositiveCategoryAllowsAmountsPastAvailableBalance() throws {
        let model = BudgetViewModel()
        let month = try Self.decodeBudgetMonth(
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
        let month = try Self.decodeBudgetMonth(
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
        let month = try Self.decodeBudgetMonth(
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
        let month = try Self.decodeBudgetMonth(
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
        let month = try Self.decodeBudgetMonth(
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
        let month = try Self.decodeBudgetMonth(
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
            month: try Self.decodeBudgetMonth(
                visibleCategoryBalance: 1_000,
                hiddenCategoryBalance: 0,
                lastMonthOverspent: 0
            ),
            alerts: []
        )
        let repository = RecordingBudgetRepository(loadedMonth: loadedMonth)

        model.selectedMonth = "2026-06"
        model.budgetMonth = try Self.decodeBudgetMonth(
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
        model.budgetMonth = try Self.decodeBudgetMonth(
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
        model.budgetMonth = try Self.decodeBudgetMonth(
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
        model.budgetMonth = try Self.decodeBudgetMonth(
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
        model.budgetMonth = try Self.decodeBudgetMonth(
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

    private static func decodeBudgetMonth(
        visibleCategoryBalance: Int,
        hiddenCategoryBalance: Int,
        categoryBudgeted: Int = 0,
        toBudget: Int = 0,
        counterpartyCategoryBalance: Int? = nil,
        lastMonthOverspent: Int
    ) throws -> BudgetMonth {
        let counterpartyCategoryJSON = counterpartyCategoryBalance.map { balance in
            """
                {
                  "id": "utilities",
                  "name": "🧹 Utilities",
                  "is_income": false,
                  "hidden": false,
                  "group_id": "bills",
                  "budgeted": 0,
                  "spent": 0,
                  "balance": \(balance),
                  "carryover": false
                },
            """
        } ?? ""

        let json = """
        {
          "month": "2026-06",
          "incomeAvailable": 0,
          "lastMonthOverspent": \(lastMonthOverspent),
          "forNextMonth": 0,
          "totalBudgeted": 0,
          "toBudget": \(toBudget),
          "fromLastMonth": 0,
          "totalIncome": 0,
          "totalSpent": 0,
          "totalBalance": 0,
          "categoryGroups": [
            {
              "id": "income",
              "name": "Income",
              "is_income": true,
              "hidden": false,
              "budgeted": 0,
              "spent": 0,
              "balance": 0,
              "categories": []
            },
            {
              "id": "bills",
              "name": "Monthly Bills",
              "is_income": false,
              "hidden": false,
              "budgeted": 0,
              "spent": 0,
              "balance": 0,
              "categories": [
                {
                  "id": "mortgage",
                  "name": "🏡 Mortgage",
                  "is_income": false,
                  "hidden": false,
                  "group_id": "bills",
                  "budgeted": \(categoryBudgeted),
                  "spent": 0,
                  "balance": \(visibleCategoryBalance),
                  "carryover": false
                },
                \(counterpartyCategoryJSON)
                {
                  "id": "old",
                  "name": "Hidden",
                  "is_income": false,
                  "hidden": true,
                  "group_id": "bills",
                  "budgeted": 0,
                  "spent": 0,
                  "balance": \(hiddenCategoryBalance),
                  "carryover": false
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        return try JSONDecoder().decode(BudgetMonth.self, from: json)
    }

    private static func decodeCategory(budgeted: Int) throws -> BudgetMonthCategory {
        let json = """
        {
          "id": "gas",
          "name": "⛽️ Gas",
          "is_income": false,
          "hidden": false,
          "group_id": "bills",
          "budgeted": \(budgeted),
          "spent": 0,
          "balance": 11220,
          "carryover": false
        }
        """.data(using: .utf8)!

        return try JSONDecoder().decode(BudgetMonthCategory.self, from: json)
    }
}

@MainActor
@Suite(.serialized)
struct BudgetRepositoryAssignmentTests {
    @Test func categoryAssignmentPatchesBudgetedOnlyAndRefetchesMonthBeforeReturning() async throws {
        let recorder = BudgetRequestRecorder()
        let repository = Self.repository { request in
            recorder.record(request)
            return try Self.response(for: request)
        }

        let loadedMonth = try await repository.assignCategoryBudgetAndRefresh(
            categoryID: "gas",
            budgeted: 5_783,
            budgetID: "budget",
            month: "2026-06"
        )

        let requests = recorder.requests()
        #expect(requests.contains("PATCH /v1/budgets/budget/months/2026-06/categories/gas"))
        #expect(requests.contains("GET /v1/budgets/budget/months"))
        #expect(requests.contains("GET /v1/budgets/budget/months/2026-06"))
        #expect(requests.contains("GET /v1/budgets/budget/months/2026-06/alerts"))
        #expect(loadedMonth.selectedMonth == "2026-06")

        let patchBody = try #require(recorder.body(for: "PATCH /v1/budgets/budget/months/2026-06/categories/gas"))
        let category = try #require(patchBody["category"] as? [String: Any])
        #expect(category["budgeted"] as? Int == 5_783)
        #expect(category["carryover"] == nil)

        try await Self.assertCategoryAssignmentThrowsWhenRefetchFailsAfterPatch()
    }

    @Test func categoryTransferPostsPayloadAndRefetchesMonthBeforeReturning() async throws {
        let recorder = BudgetRequestRecorder()
        let repository = Self.repository { request in
            recorder.record(request)
            return try Self.response(for: request)
        }

        let loadedMonth = try await repository.moveMoneyAndRefresh(
            command: BudgetMoveMoneyCommand(
                fromCategoryID: "mortgage",
                toCategoryID: nil,
                amount: 2_500
            ),
            budgetID: "budget",
            month: "2026-06"
        )

        let requests = recorder.requests()
        #expect(requests.contains("POST /v1/budgets/budget/months/2026-06/categorytransfers"))
        #expect(requests.contains("GET /v1/budgets/budget/months"))
        #expect(requests.contains("GET /v1/budgets/budget/months/2026-06"))
        #expect(requests.contains("GET /v1/budgets/budget/months/2026-06/alerts"))
        #expect(loadedMonth.selectedMonth == "2026-06")

        let postBody = try #require(recorder.body(for: "POST /v1/budgets/budget/months/2026-06/categorytransfers"))
        let transfer = try #require(postBody["categorytransfer"] as? [String: Any])
        #expect(transfer["fromCategoryId"] as? String == "mortgage")
        #expect(transfer["toCategoryId"] == nil)
        #expect(transfer["amount"] as? Int == 2_500)
    }

    @Test func templateApplyPostsPayloadAndRefetchesMonthBeforeReturning() async throws {
        let recorder = BudgetRequestRecorder()
        let repository = Self.repository { request in
            recorder.record(request)
            return try Self.response(for: request)
        }

        let loadedMonth = try await repository.applyBudgetTemplateAndRefresh(
            command: .category("gas"),
            budgetID: "budget",
            month: "2026-06"
        )

        let requests = recorder.requests()
        #expect(requests.contains("POST /v1/budgets/budget/months/2026-06/templates/apply"))
        #expect(requests.contains("GET /v1/budgets/budget/months"))
        #expect(requests.contains("GET /v1/budgets/budget/months/2026-06"))
        #expect(requests.contains("GET /v1/budgets/budget/months/2026-06/alerts"))
        #expect(loadedMonth.selectedMonth == "2026-06")

        let postBody = try #require(recorder.body(for: "POST /v1/budgets/budget/months/2026-06/templates/apply"))
        #expect(postBody["mode"] as? String == "overwrite")
        #expect(postBody["categoryIds"] as? [String] == ["gas"])
    }

    private static func assertCategoryAssignmentThrowsWhenRefetchFailsAfterPatch() async throws {
        let recorder = BudgetRequestRecorder()
        let repository = Self.repository { request in
            recorder.record(request)
            if request.httpMethod == "GET",
               request.url?.path.hasSuffix("/months/2026-06/alerts") == true {
                return try Self.errorResponse(for: request)
            }
            return try Self.response(for: request)
        }

        do {
            _ = try await repository.assignCategoryBudgetAndRefresh(
                categoryID: "gas",
                budgeted: 5_783,
                budgetID: "budget",
                month: "2026-06"
            )
            Issue.record("Expected refetch failure to throw")
        } catch {
            let requests = recorder.requests()
            #expect(requests.contains("PATCH /v1/budgets/budget/months/2026-06/categories/gas"))
            #expect(requests.contains("GET /v1/budgets/budget/months/2026-06/alerts"))
        }
    }

    private static func repository(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> ActualDataStore {
        BudgetStubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BudgetStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = ActualAPIClient(
            baseURL: URL(string: "http://actual.test/v1")!,
            apiKey: "test-key",
            session: session
        )
        return ActualDataStore(clientProvider: { client })
    }

    private static func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? ""

        if method == "PATCH", path.hasSuffix("/months/2026-06/categories/gas") {
            return (try okResponse(for: request), #"{"message":"Category updated"}"#.data(using: .utf8)!)
        }

        if method == "POST", path.hasSuffix("/months/2026-06/categorytransfers") {
            return (try okResponse(for: request), #"{"message":"Category transfer created"}"#.data(using: .utf8)!)
        }

        if method == "POST", path.hasSuffix("/months/2026-06/templates/apply") {
            return (
                try okResponse(for: request),
                #"{"data":{"type":"template","message":"ok","pre":null,"sticky":null}}"#.data(using: .utf8)!
            )
        }

        if method == "GET", path.hasSuffix("/months") {
            return (try okResponse(for: request), #"{"data":["2026-06"]}"#.data(using: .utf8)!)
        }

        if method == "GET", path.hasSuffix("/months/2026-06") {
            return (try okResponse(for: request), budgetMonthData())
        }

        if method == "GET", path.hasSuffix("/months/2026-06/alerts") {
            return (try okResponse(for: request), #"{"data":{"month":"2026-06","alerts":[]}}"#.data(using: .utf8)!)
        }

        return try errorResponse(for: request)
    }

    private static func okResponse(for request: URLRequest) throws -> HTTPURLResponse {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            throw TestError("Could not build HTTP response")
        }

        return response
    }

    private static func errorResponse(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            throw TestError("Could not build HTTP response")
        }

        return (response, #"{"error":"server failed"}"#.data(using: .utf8)!)
    }

    private static func budgetMonthData() -> Data {
        """
        {
          "data": {
            "month": "2026-06",
            "incomeAvailable": 0,
            "lastMonthOverspent": 0,
            "forNextMonth": 0,
            "totalBudgeted": 0,
            "toBudget": 0,
            "fromLastMonth": 0,
            "totalIncome": 0,
            "totalSpent": 0,
            "totalBalance": 0,
            "categoryGroups": []
          }
        }
        """.data(using: .utf8)!
    }
}

actor RecordingBudgetRepository: BudgetRepositoryProtocol {
    private let loadedMonth: LoadedBudgetMonth
    private let assignError: Error?
    private let moveError: Error?
    private let templateError: Error?
    private var assignments: [RecordedBudgetAssignment] = []
    private var moves: [RecordedBudgetMove] = []
    private var templates: [RecordedBudgetTemplate] = []
    private var didAssignCallbackFinished = false
    private var didMoveCallbackFinished = false
    private var didApplyCallbackFinished = false

    init(
        loadedMonth: LoadedBudgetMonth = LoadedBudgetMonth(
            availableMonths: ["2026-06"],
            selectedMonth: "2026-06",
            month: try! JSONDecoder().decode(BudgetMonth.self, from: """
            {
              "month": "2026-06",
              "incomeAvailable": 0,
              "lastMonthOverspent": 0,
              "forNextMonth": 0,
              "totalBudgeted": 0,
              "toBudget": 0,
              "fromLastMonth": 0,
              "totalIncome": 0,
              "totalSpent": 0,
              "totalBalance": 0,
              "categoryGroups": []
            }
            """.data(using: .utf8)!),
            alerts: []
        ),
        assignError: Error? = nil,
        moveError: Error? = nil,
        templateError: Error? = nil
    ) {
        self.loadedMonth = loadedMonth
        self.assignError = assignError
        self.moveError = moveError
        self.templateError = templateError
    }

    func budgets() async throws -> [ActualBudget] {
        []
    }

    func currentBudgetMonth(
        budgetID: String,
        preferredMonth: String
    ) async throws -> LoadedBudgetMonth {
        loadedMonth
    }

    func budgetMonth(
        budgetID: String,
        selectedMonth: String
    ) async throws -> LoadedBudgetMonth {
        loadedMonth
    }

    func assignCategoryBudgetAndRefresh(
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        assignments.append(
            RecordedBudgetAssignment(
                categoryID: categoryID,
                budgeted: budgeted,
                budgetID: budgetID,
                month: month
            )
        )

        if let assignError {
            throw assignError
        }

        await didAssign()
        didAssignCallbackFinished = true
        return loadedMonth
    }

    func moveMoneyAndRefresh(
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        try await moveMoneyAndRefresh(
            commands: [command],
            budgetID: budgetID,
            month: month,
            didMove: didMove
        )
    }

    func moveMoneyAndRefresh(
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        for command in commands {
            moves.append(
                RecordedBudgetMove(
                    command: command,
                    budgetID: budgetID,
                    month: month
                )
            )
        }

        if let moveError {
            throw moveError
        }

        await didMove()
        didMoveCallbackFinished = true
        return loadedMonth
    }

    func applyBudgetTemplateAndRefresh(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        templates.append(
            RecordedBudgetTemplate(
                command: command,
                budgetID: budgetID,
                month: month
            )
        )

        if let templateError {
            throw templateError
        }

        await didApply()
        didApplyCallbackFinished = true
        return loadedMonth
    }

    func onlyAssignment() throws -> RecordedBudgetAssignment {
        try #require(assignments.first)
    }

    func onlyMove() throws -> RecordedBudgetMove {
        try #require(moves.first)
    }

    func recordedMoves() -> [RecordedBudgetMove] {
        moves
    }

    func onlyTemplate() throws -> RecordedBudgetTemplate {
        try #require(templates.first)
    }

    func didAssignFinished() -> Bool {
        didAssignCallbackFinished
    }

    func didMoveFinished() -> Bool {
        didMoveCallbackFinished
    }

    func didApplyFinished() -> Bool {
        didApplyCallbackFinished
    }
}

struct RecordedBudgetAssignment: Sendable {
    let categoryID: String
    let budgeted: Int
    let budgetID: String
    let month: String
}

struct RecordedBudgetMove: Sendable {
    let command: BudgetMoveMoneyCommand
    let budgetID: String
    let month: String
}

struct RecordedBudgetTemplate: Sendable {
    let command: BudgetTemplateCommand
    let budgetID: String
    let month: String
}

final class BudgetStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: TestError("Missing URLProtocol handler"))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class BudgetRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [String] = []
    private var recordedBodies: [String: [String: Any]] = [:]

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }

        let method = request.httpMethod ?? ""
        let url = request.url
        let path = url?.path ?? ""
        let query = url?.query.map { "?\($0)" } ?? ""
        let key = "\(method) \(path)\(query)"
        recordedRequests.append(key)

        if let body = request.bodyDataForTesting,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            recordedBodies[key] = json
        }
    }

    func requests() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func body(for request: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return recordedBodies[request]
    }
}

private extension URLRequest {
    var bodyDataForTesting: Data? {
        if let httpBody {
            return httpBody
        }

        guard let httpBodyStream else {
            return nil
        }

        httpBodyStream.open()
        defer { httpBodyStream.close() }

        var data = Data()
        let bufferSize = 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while httpBodyStream.hasBytesAvailable {
            let readCount = httpBodyStream.read(buffer, maxLength: bufferSize)
            if readCount <= 0 {
                break
            }

            data.append(buffer, count: readCount)
        }

        return data.isEmpty ? nil : data
    }
}
