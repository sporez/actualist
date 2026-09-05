import Testing
@testable import Actualist

@MainActor
struct IPadAssignmentHandoffTests {
    @Test func compactDraftCannotFollowNavigationToAnotherMonth() async throws {
        let repository = BudgetViewportTestRepository()
        for month in ["2026-07", "2026-08"] { await repository.set(BudgetViewportFixtures.loaded(month)) }
        let model = BudgetViewModel()
        await model.selectMonth("2026-07", budgetID: "budget", repository: repository)
        model.beginAssignmentEditing(for: try #require(model.visibleGroups.first?.categories.first))
        model.appendAssignmentDigit(9)
        await model.selectMonth("2026-08", budgetID: "budget", repository: repository)
        #expect(model.assignmentDraft == nil)
        #expect(await model.submitAssignment(budgetID: "budget", repository: repository) == false)
        #expect(try await repository.budgetMonth(budgetID: "budget", selectedMonth: "2026-08").month.totalBudgeted == 100)
    }

    @Test func latestCompactExpansionReplacesObsoleteWideSet() async {
        let repository = BudgetViewportTestRepository()
        await repository.set(BudgetViewportFixtures.loaded("2026-07"))
        let compact = BudgetViewModel()
        await compact.selectMonth("2026-07", budgetID: "budget", repository: repository)
        let viewport = BudgetViewportModel(repository: repository)
        await viewport.adoptCompactState(compact, budgetID: "budget")
        viewport.expandedGroupIDs = []
        compact.expandedGroupIDs = ["group", "deleted"]
        await viewport.adoptCompactState(compact, budgetID: "budget")
        #expect(viewport.expandedGroupIDs == ["group"])
        compact.expandedGroupIDs = []
        await viewport.adoptCompactState(compact, budgetID: "budget")
        #expect(viewport.expandedGroupIDs.isEmpty)
    }
}

extension IPadAssignmentHandoffTests {
    @Test(arguments: [BudgetAssignmentInputMode.direct, .addition, .subtraction])
    func secondMonthDraftSurvivesBothPresentationsAndWritesOnlyCapturedSQLiteMonth(mode: BudgetAssignmentInputMode) async throws {
        let support = LocalFirstActualStoreTests()
        let bundle = try await support.makeOpenedWritableStoreBundle(additionalFixtureSQL: "INSERT INTO zero_budgets VALUES (202608, 'groceries', 900, 1);")
        let state = try support.makeAppState(for: bundle)
        let session = AdaptiveBudgetSession(repository: bundle.store)
        await session.update(mode: .compact, budgetID: "group-1", appState: state).value
        await session.compactModel.selectMonth("2026-07", budgetID: "group-1", repository: bundle.store)
        await session.update(mode: .sidebar, budgetID: "group-1", appState: state).value
        session.viewport.setResolvedMonthCount(2)
        await session.viewport.refreshVisibleMonths()
        let julyBefore = try await bundle.store.fetchBudgetMonthUncached(budgetID: "group-1", month: "2026-07")
        session.viewport.beginAssignmentEditing(categoryID: "groceries", month: "2026-08")
        session.viewport.setAssignmentInputMode(mode)
        session.viewport.assignmentWorkflow.replaceInputDigits("50")
        let draft = try #require(session.viewport.assignmentWorkflow.draft)
        await session.update(mode: .compact, budgetID: "group-1", appState: state).value
        #expect(session.compactModel.selectedMonth == "2026-08")
        #expect(session.compactModel.assignmentDraft == draft)
        await session.update(mode: .sidebar, budgetID: "group-1", appState: state).value
        #expect(session.viewport.anchorMonth == "2026-07")
        #expect(session.viewport.assignmentWorkflow.draft == draft)
        await session.update(mode: .compact, budgetID: "group-1", appState: state).value
        #expect(await session.compactModel.submitAssignment(budgetID: "group-1", repository: bundle.store))
        let july = try await bundle.store.fetchBudgetMonthUncached(budgetID: "group-1", month: "2026-07")
        let august = try await bundle.store.fetchBudgetMonthUncached(budgetID: "group-1", month: "2026-08")
        #expect(july.month == julyBefore.month)
        #expect(august.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }?.budgeted == draft.finalBudgeted)
        #expect(await session.compactModel.submitAssignment(budgetID: "group-1", repository: bundle.store) == false)
    }

    @Test func canceledCompactDraftDoesNotWriteEitherSQLiteMonth() async throws {
        let support = LocalFirstActualStoreTests()
        let bundle = try await support.makeOpenedWritableStoreBundle(additionalFixtureSQL: "INSERT INTO zero_budgets VALUES (202608, 'groceries', 900, 1);")
        let state = try support.makeAppState(for: bundle)
        let session = AdaptiveBudgetSession(repository: bundle.store)
        await session.update(mode: .compact, budgetID: "group-1", appState: state).value
        await session.compactModel.selectMonth("2026-07", budgetID: "group-1", repository: bundle.store)
        let before = try await bundle.store.fetchBudgetMonthUncached(budgetID: "group-1", month: "2026-07")
        let category = try #require(before.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })
        session.compactModel.beginAssignmentEditing(for: category)
        session.compactModel.appendAssignmentDigit(9)
        await session.update(mode: .sidebar, budgetID: "group-1", appState: state).value
        #expect(session.viewport.assignmentWorkflow.draft?.inputDigits == "9")
        await session.viewport.moveAnchor(by: 1)
        await session.update(mode: .compact, budgetID: "group-1", appState: state).value
        #expect(session.compactModel.assignmentDraft == nil)
        #expect(await session.compactModel.submitAssignment(budgetID: "group-1", repository: bundle.store) == false)
        #expect(try await bundle.store.fetchBudgetMonthUncached(budgetID: "group-1", month: "2026-07").month == before.month)
        #expect(try await bundle.store.fetchBudgetMonthUncached(budgetID: "group-1", month: "2026-08").month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }?.budgeted == 900)
    }

    @Test func carryoverPolicyRefreshesOnEveryActivation() async throws {
        let support = LocalFirstActualStoreTests()
        let bundle = try await support.makeOpenedWritableStoreBundle()
        let state = try support.makeAppState(for: bundle)
        let session = AdaptiveBudgetSession(repository: bundle.store)
        for enabled in [true, false] {
            await session.update(mode: .sidebar, budgetID: "group-1", appState: state).value
            state.updateIncludeCarryoverCategoriesInOverspentAlerts(enabled)
            await session.update(mode: .compact, budgetID: "group-1", appState: state).value
            #expect(session.compactModel.includeCarryoverCategoriesInOverspentAlerts == enabled)
        }
    }

    @Test func jpyInputAndBlockedWriteKeepOneContextAcrossHandoff() async throws {
        let repository = BudgetViewportTestRepository()
        var loaded = BudgetViewportFixtures.loaded("2026-07", budgeted: 1000)
        loaded.currency = .jpy
        await repository.set(loaded)
        let workflow = BudgetAssignmentWorkflow()
        let compact = BudgetViewModel(assignmentWorkflow: workflow)
        await compact.selectMonth("2026-07", budgetID: "budget", repository: repository)
        let viewport = BudgetViewportModel(repository: repository, assignmentWorkflow: workflow)
        await viewport.adoptCompactState(compact, budgetID: "budget")
        viewport.beginAssignmentEditing(categoryID: "groceries", month: "2026-07")
        #expect(await viewport.handleHardwareInput("+"))
        #expect(await viewport.handleHardwareInput("1"))
        #expect(await viewport.handleHardwareInput("2"))
        #expect(workflow.draft?.finalBudgeted == 1012)
        await repository.blockAssignment()
        let write = Task { await viewport.submitAssignment() }
        await repository.waitUntilAssignmentBlocked()
        await viewport.prepareCompactState(compact)
        #expect(workflow.isSubmitting)
        #expect(await compact.submitAssignment(budgetID: "budget", repository: repository) == false)
        await repository.releaseAssignment()
        #expect(await write.value)
        #expect(try await repository.budgetMonth(budgetID: "budget", selectedMonth: "2026-07").month.totalBudgeted == 1012)
    }
}

extension IPadAssignmentHandoffTests {
    @Test func explicitHiddenExpansionSurvivesHandoffAndRefresh() async {
        let repository = BudgetViewportTestRepository()
        await repository.set(BudgetViewportFixtures.loaded("2026-07", groupHidden: true))
        let compact = BudgetViewModel()
        await compact.selectMonth("2026-07", budgetID: "budget", repository: repository)
        #expect(compact.expandedGroupIDs.isEmpty)
        compact.expandedGroupIDs = ["group", "deleted"]
        let viewport = BudgetViewportModel(repository: repository)
        viewport.setShowHidden(true)
        await viewport.adoptCompactState(compact, budgetID: "budget")
        #expect(viewport.expandedGroupIDs == ["group"])
        await viewport.refreshVisibleMonths()
        await viewport.prepareCompactState(compact)
        #expect(compact.expandedGroupIDs == ["group"])
        viewport.expandedGroupIDs = []
        await viewport.prepareCompactState(compact)
        #expect(compact.expandedGroupIDs.isEmpty)
    }

    @Test func monthNavigationDetachesBlockedWriteFromReplacementDraft() async {
        let repository = BudgetViewportTestRepository()
        for month in ["2026-07", "2026-08"] { await repository.set(BudgetViewportFixtures.loaded(month)) }
        let model = BudgetViewportModel(repository: repository)
        await model.load(budgetID: "budget", anchorMonth: "2026-07")
        model.beginAssignmentEditing(categoryID: "groceries", month: "2026-07")
        model.appendKeypadDigit(7)
        await repository.blockAssignment()
        let write = Task { await model.submitAssignment() }
        await repository.waitUntilAssignmentBlocked()
        await model.moveAnchor(by: 1)
        model.beginAssignmentEditing(categoryID: "groceries", month: "2026-08")
        model.appendKeypadDigit(9)
        await repository.releaseAssignment()
        #expect(await write.value == false)
        #expect(model.anchorMonth == "2026-08")
        #expect(model.assignmentWorkflow.draft?.inputDigits == "9")
        #expect(model.assignmentWorkflow.errorMessage == nil)
        #expect(model.assignmentWorkflow.completionRevision == 1)
    }
}
