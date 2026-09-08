import Testing
@testable import Actualist

@MainActor
struct TrackingBudgetWorkflowTests {
    private let identity = BudgetModeIdentity(storageID: "budget", table: .tracking, revision: "r1")

    @Test func assignmentCapturesModeIdentityAndConversionInvalidatesDraft() throws {
        let workflow = BudgetAssignmentWorkflow()
        let category = try BudgetViewModelFixtures.decodeCategory(budgeted: 100)

        workflow.begin(for: category, budgetID: "budget", month: "2026-07", modeIdentity: identity)
        #expect(workflow.context?.modeIdentity == identity)
        workflow.reconcile(budgetID: "budget", month: "2026-07", categoryIDs: [category.id])
        #expect(workflow.isPresented)
        workflow.invalidate()
        #expect(!workflow.isPresented)
    }

    @Test func moveMoneyCapturesModeIdentityAndRejectsNewMode() throws {
        let workflow = BudgetMoveMoneyWorkflow()
        let category = try BudgetViewModelFixtures.decodeCategory(budgeted: 100)

        workflow.begin(for: category, budgetID: "budget", month: "2026-07", modeIdentity: identity)
        #expect(workflow.context?.modeIdentity == identity)
        let converted = BudgetModeIdentity(storageID: "budget", table: .envelope, revision: "r2")
        workflow.reconcile(budgetID: "budget", month: "2026-07", modeIdentity: converted)
        #expect(!workflow.isPresented)
    }

    @Test func templateRequestBecomesStaleAfterConversion() {
        let workflow = BudgetTemplateWorkflow()
        let request = workflow.beginRequest(budgetID: "budget", month: "2026-07", modeIdentity: identity)
        workflow.noteSelectionChange()

        #expect(!workflow.isCurrent(
            request,
            currentBudgetID: "budget",
            currentMonth: "2026-07",
            currentModeIdentity: identity
        ))
    }

    @Test func trackingViewModelRefusesMoveMoneyAndCoverEntryPoints() throws {
        let month = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: -100,
            hiddenCategoryBalance: 0,
            lastMonthOverspent: 0
        )
        let model = BudgetViewModel(
            initialMonth: LoadedBudgetMonth(
                modeIdentity: identity,
                availableMonths: ["2026-07"],
                selectedMonth: "2026-07",
                month: month,
                alerts: [],
                isTrackingBudget: true
            ),
            initialBudgetID: "budget"
        )
        let category = try #require(model.visibleGroups.first { !$0.isIncome }?.visibleCategories.first)

        model.beginMoveMoney(for: category.id)
        #expect(!model.isMoveMoneyPresented)
        #expect(!model.canOpenOverspentCover)
        #expect(!model.canBeginOverspentCoverSelection)
    }

    @Test func applyingAnOldTemplateReviewExplainsConversionWithoutWriting() async throws {
        let converted = BudgetModeIdentity(storageID: "budget", table: .envelope, revision: "r2")
        let loaded = LoadedBudgetMonth(
            modeIdentity: converted, availableMonths: ["2026-06"], selectedMonth: "2026-06",
            month: try BudgetViewModelFixtures.decodeBudgetMonth(
                visibleCategoryBalance: 0, hiddenCategoryBalance: 0, lastMonthOverspent: 0), alerts: []
        )
        let model = BudgetViewModel(initialMonth: loaded, initialBudgetID: "budget")
        let repository = RecordingBudgetRepository(loadedMonth: loaded)
        let applied = await model.applyMonthTemplate(
            .overwrite, budgetID: "budget", expectedMode: identity, repository: repository
        )
        #expect(!applied)
        #expect(model.errorMessage == BudgetModeWriteError.budgetChanged.localizedDescription)
        #expect(model.budgetMonth == loaded.month)
    }

}
