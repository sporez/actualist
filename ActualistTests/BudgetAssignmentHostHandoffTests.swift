import Testing
@testable import Actualist

@MainActor
struct BudgetAssignmentHostHandoffTests {
    private func presentedViewport() async throws -> BudgetViewportModel {
        let repository = BudgetViewportTestRepository()
        await repository.set(BudgetViewportFixtures.loaded("2026-07"))
        let viewport = BudgetViewportModel(repository: repository)
        await viewport.load(budgetID: "budget", anchorMonth: "2026-07")
        viewport.beginAssignmentEditing(categoryID: "groceries", month: "2026-07")
        viewport.assignmentWorkflow.replaceInputDigits("50")
        try #require(viewport.assignmentWorkflow.isPresented)
        return viewport
    }

    @Test func dismissalWhileCompactOwnsTheHostKeepsTheDraft() async throws {
        let viewport = try await presentedViewport()
        viewport.assignmentHost = .compact
        viewport.assignmentPopoverDismissed(categoryID: "groceries", month: "2026-07")
        #expect(viewport.assignmentWorkflow.draft?.inputDigits == "50")
    }

    @Test func dismissalWhileSidebarOwnsTheHostCancels() async throws {
        let viewport = try await presentedViewport()
        viewport.assignmentPopoverDismissed(categoryID: "groceries", month: "2026-07")
        #expect(viewport.assignmentWorkflow.draft == nil)
    }

    @Test func dismissalOfADifferentCellDoesNothing() async throws {
        let viewport = try await presentedViewport()
        viewport.assignmentPopoverDismissed(categoryID: "other", month: "2026-07")
        #expect(viewport.assignmentWorkflow.draft?.inputDigits == "50")
    }

    @Test func sessionSetsTheHostBeforePresentingTheContext() async throws {
        let support = LocalFirstActualStoreTests()
        let bundle = try await support.makeOpenedWritableStoreBundle()
        let state = try support.makeAppState(for: bundle)
        let session = AdaptiveBudgetSession(repository: bundle.store)
        await session.update(mode: .compact, budgetID: "group-1", appState: state).value
        #expect(session.viewport.assignmentHost == .compact)
        await session.update(mode: .sidebar, budgetID: "group-1", appState: state).value
        #expect(session.viewport.assignmentHost == .sidebar)
        let shrinking = session.update(mode: .compact, budgetID: "group-1", appState: state)
        #expect(session.viewport.assignmentHost == .sidebar)
        await shrinking.value
        #expect(session.viewport.assignmentHost == .compact)
    }
}
