import Testing
@testable import Actualist

@MainActor
struct BudgetMonthSwipeTransitionTests {
    private func model() -> BudgetViewModel {
        BudgetViewModel(initialMonth: BudgetViewportFixtures.loaded("2026-12"), initialBudgetID: "budget")
    }

    @Test func releaseWhileLoadingWaitsThenCompletesOnceAnimationFinishes() async throws {
        let model = model()
        model.expandedGroupIDs = []
        let repository = BudgetViewportTestRepository()
        await repository.set(BudgetViewportFixtures.loaded("2027-01"))
        await repository.block("2027-01")
        let transition = BudgetMonthSwipeTransition()
        let read = try #require(transition.prepare(.next, model: model, budgetID: "budget") {
            try await repository.budgetMonth(budgetID: $0, selectedMonth: $1)
        })
        await repository.waitUntilReadBlocked("2027-01")
        transition.release(commit: true)
        #expect(transition.isReleased)
        #expect(transition.commitReadyID == nil)
        #expect(model.selectedMonth == "2026-12")
        await repository.release("2027-01")
        await read.value
        let id = try #require(transition.commitReadyID)
        #expect(transition.preview?.selectedMonth == "2027-01")
        #expect(transition.preview?.expandedGroupIDs.isEmpty == true)
        #expect(model.selectedMonth == "2026-12")
        await transition.complete(id: id, model: model, repository: repository)?.value
        #expect(model.selectedMonth == "2027-01")
        #expect(model.expandedGroupIDs.isEmpty)
        #expect(transition.request == nil)
        #expect(transition.complete(id: id, model: model, repository: repository) == nil)
    }

    @Test func shortReleaseRetainsPreviewForSpringAndDoesNotChangeMonth() async throws {
        let model = model()
        let transition = BudgetMonthSwipeTransition()
        await transition.prepare(.next, model: model, budgetID: "budget") { _, month in
            BudgetViewportFixtures.loaded(month)
        }?.value
        let preview = try #require(transition.preview)
        transition.release(commit: false)
        #expect(transition.preview === preview)
        #expect(transition.commitReadyID == nil)
        #expect(transition.isReleased)
        #expect(model.selectedMonth == "2026-12")
        transition.cancel()
        #expect(transition.preview == nil)
    }

    @Test func cancelledDelayedPreviewCannotReplaceANewerGesture() async throws {
        let model = model()
        let repository = BudgetViewportTestRepository()
        await repository.set(BudgetViewportFixtures.loaded("2027-01"))
        await repository.block("2027-01")
        let transition = BudgetMonthSwipeTransition()
        let old = try #require(transition.prepare(.next, model: model, budgetID: "budget") {
            try await repository.budgetMonth(budgetID: $0, selectedMonth: $1)
        })
        await repository.waitUntilReadBlocked("2027-01")
        transition.cancel()
        await transition.prepare(.previous, model: model, budgetID: "budget") { _, month in
            BudgetViewportFixtures.loaded(month)
        }?.value
        let newID = transition.request?.id
        await repository.release("2027-01")
        await old.value
        #expect(transition.request?.id == newID)
        #expect(transition.preview?.selectedMonth == "2026-11")
        #expect(model.selectedMonth == "2026-12")
    }

    @Test func changedContextAndActiveDraftInvalidatePreview() async throws {
        let model = model()
        let transition = BudgetMonthSwipeTransition()
        await transition.prepare(.next, model: model, budgetID: "budget") { _, month in
            BudgetViewportFixtures.loaded(month)
        }?.value
        model.beginAssignmentEditing(for: try #require(model.visibleGroups.first?.categories.first))
        transition.invalidateIfNeeded(model: model)
        #expect(transition.request == nil)
        #expect(model.isAssignmentKeypadPresented)
    }

    @Test func failedPreviewKeepsCurrentMonthAndAllowsRetry() async {
        let model = model()
        let repository = BudgetViewportTestRepository()
        let transition = BudgetMonthSwipeTransition()
        await transition.prepare(.next, model: model, budgetID: "budget") {
            try await repository.budgetMonth(budgetID: $0, selectedMonth: $1)
        }?.value
        #expect(transition.request == nil)
        #expect(model.errorMessage != nil)
        #expect(model.selectedMonth == "2026-12")
        await transition.prepare(.next, model: model, budgetID: "budget") { _, month in
            BudgetViewportFixtures.loaded(month)
        }?.value
        #expect(transition.preview != nil)
    }
}
