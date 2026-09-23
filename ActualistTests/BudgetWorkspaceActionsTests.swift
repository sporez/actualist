import Foundation
import Testing
@testable import Actualist

struct BudgetWorkspaceActionsTests {
    @Test @MainActor func categoryConfirmationWritesCapturedMonthAndCategoryAndRefreshesViewport() async throws {
        let month = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 0,
            hiddenCategoryBalance: 0,
            visibleCategoryHasTemplate: true,
            lastMonthOverspent: 0
        )
        let modeIdentity = BudgetModeIdentity(storageID: "file-1", table: .envelope, revision: nil)
        let loaded = LoadedBudgetMonth(
            modeIdentity: modeIdentity,
            availableMonths: ["2026-06"],
            selectedMonth: "2026-06",
            month: month,
            alerts: []
        )
        let repository = RecordingBudgetRepository(loadedMonth: loaded)
        let viewport = BudgetViewportModel(repository: repository)
        await viewport.load(budgetID: "file-1", anchorMonth: "2026-06")
        let actions = BudgetWorkspaceActions(viewport: viewport)
        actions.requestCategoryTemplate(.init(categoryID: "mortgage", month: "2026-06"))

        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let appState = AppState(settingsStore: AppSettingsStore(defaults: defaults))
        appState.settings.selectedBudgetID = "file-1"
        let reviewRevision = BudgetTemplateReviewRevision(
            month: "2026-06", modeIdentity: modeIdentity,
            messageCount: 0, maxMessageTimestamp: nil
        )
        // The confirmation sheet clears its binding before invoking apply.
        // Clearing the binding must preserve the captured assignment draft.
        actions.setConfirmation(nil)
        await actions.applyConfirmation(.category, reviewRevision: reviewRevision, using: appState)

        let recorded = try await repository.onlyTemplate()
        #expect(recorded.command == .category("mortgage"))
        #expect(recorded.budgetID == "file-1")
        #expect(recorded.month == "2026-06")
        #expect(await repository.recordedReviewedTemplateRevisions() == [reviewRevision])
        #expect(viewport.snapshot(for: "2026-06") != nil)
    }
    @Test @MainActor func activationOpensCategoryRouteAfterLoadingAndConsumesOnce() async throws {
        let support = LocalFirstActualStoreTests()
        let bundle = try await support.makeOpenedWritableStoreBundle()
        let state = try support.makeAppState(for: bundle)
        let repository = BudgetViewportTestRepository()
        await repository.set(BudgetViewportFixtures.loaded("2026-07"))
        let compact = BudgetViewModel()
        await compact.selectMonth("2026-07", budgetID: "group-1", repository: repository)
        let viewport = BudgetViewportModel(repository: repository)
        let actions = BudgetWorkspaceActions(viewport: viewport)
        state.routeCoordinator.enqueue(.category(id: "groceries", month: "2026-07"))
        await actions.activate(using: state, compactModel: compact, monthCount: 1)
        #expect(viewport.selectedCategoryDetails?.category.id == "groceries")
        #expect(state.routeCoordinator.pendingRoute == nil)
        viewport.closeInspector()
        await actions.activate(using: state, compactModel: compact, monthCount: 1)
        #expect(viewport.selectedCategoryDetails == nil)
    }

    @Test @MainActor func olderCategoryLoadDoesNotConsumeNewerRoute() async throws {
        let support = LocalFirstActualStoreTests()
        let bundle = try await support.makeOpenedWritableStoreBundle()
        let state = try support.makeAppState(for: bundle)
        let repository = BudgetViewportTestRepository()
        await repository.set(BudgetViewportFixtures.loaded("2026-07"))
        await repository.block("2026-07")
        let viewport = BudgetViewportModel(repository: repository)
        let actions = BudgetWorkspaceActions(viewport: viewport)
        state.routeCoordinator.enqueue(.category(id: "groceries", month: "2026-07"))
        let old = Task { await actions.applyRoute(using: state) }
        await repository.waitUntilReadBlocked("2026-07")
        state.routeCoordinator.enqueue(.history)
        await repository.release("2026-07")
        await old.value
        #expect(state.routeCoordinator.pendingRoute == .history)
        #expect(viewport.selectedCategoryDetails == nil)
        await actions.applyRoute(using: state)
        #expect(actions.sheet == .history)
        #expect(state.routeCoordinator.pendingRoute == nil)
    }

}
