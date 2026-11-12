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

    @Test @MainActor func monthNoteTitleUsesTheRegionMonthNameNotTheMonthID() {
        let actions = BudgetWorkspaceActions(viewport: BudgetViewportModel(repository: BudgetViewportTestRepository()))
        actions.openMonthNote("2026-08")
        guard case .note(let target) = actions.sheet else {
            Issue.record("Expected the month note sheet")
            return
        }
        #expect(target.entityID == "2026-08")
        #expect(target.title == BudgetMonthNavigationPresentation.title(for: "2026-08"))
        #expect(target.title != "2026-08")
    }

    // MARK: Category actions on the wide layout (real store, in-memory viewport)

    @MainActor private struct WideCategoryFixture {
        let state: AppState
        let viewport: BudgetViewportModel
        let actions: BudgetWorkspaceActions
        let store: LocalFirstActualStore
        let group: BudgetMonthCategoryGroup
    }

    @MainActor private func wideCategoryFixture() async throws -> WideCategoryFixture {
        let support = LocalFirstActualStoreTests()
        let bundle = try await support.makeOpenedWritableStoreBundle()
        let state = try support.makeAppState(for: bundle)
        state.settings.selectedBudgetID = "group-1"
        let viewport = BudgetViewportModel(repository: bundle.store)
        await viewport.load(budgetID: "group-1", anchorMonth: "2026-07")
        let group = try #require(viewport.snapshot(for: "2026-07")?.month.categoryGroups.first { $0.id == "group" })
        return WideCategoryFixture(
            state: state, viewport: viewport, actions: BudgetWorkspaceActions(viewport: viewport),
            store: bundle.store, group: group
        )
    }

    @MainActor private func shownCategory(_ id: String, in viewport: BudgetViewportModel) -> BudgetMonthCategory? {
        viewport.snapshot(for: "2026-07")?.month.categoryGroups.flatMap(\.categories).first { $0.id == id }
    }

    @Test @MainActor func wideHideWritesThenRefreshesTheViewport() async throws {
        let fixture = try await wideCategoryFixture()
        let groceries = try #require(shownCategory("groceries", in: fixture.viewport))
        #expect(!BudgetCategoryVisibility.isHidden(groceries.hidden))
        await fixture.actions.setCategoryHidden(
            true, category: groceries, group: fixture.group, month: "2026-07", using: fixture.state
        )
        let refreshed = try #require(shownCategory("groceries", in: fixture.viewport))
        #expect(BudgetCategoryVisibility.isHidden(refreshed.hidden))
        #expect(fixture.actions.errorMessage == nil)
    }

    @Test @MainActor func wideHideInAHiddenGroupFailsWithoutRefreshing() async throws {
        let fixture = try await wideCategoryFixture()
        let groceries = try #require(shownCategory("groceries", in: fixture.viewport))
        let hiddenGroup = BudgetMonthCategoryGroup(
            id: fixture.group.id, name: fixture.group.name, isIncome: false, hidden: true,
            budgeted: 0, spent: 0, balance: 0, categories: fixture.group.categories
        )
        await fixture.actions.setCategoryHidden(
            true, category: groceries, group: hiddenGroup, month: "2026-07", using: fixture.state
        )
        #expect(fixture.actions.errorMessage == "Show the group first to change this category.")
        #expect(!BudgetCategoryVisibility.isHidden(try #require(shownCategory("groceries", in: fixture.viewport)).hidden))
    }

    @Test @MainActor func wideHideDoesNotWriteWhenTheSelectedBudgetIsNotTheVisibleOne() async throws {
        let fixture = try await wideCategoryFixture()
        let groceries = try #require(shownCategory("groceries", in: fixture.viewport))
        fixture.state.settings.selectedBudgetID = "other-budget"
        await fixture.actions.setCategoryHidden(
            true, category: groceries, group: fixture.group, month: "2026-07", using: fixture.state
        )
        let stored = try await fixture.store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let storedGroceries = try #require(stored.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })
        #expect(!BudgetCategoryVisibility.isHidden(storedGroceries.hidden))
        #expect(fixture.actions.errorMessage == nil)
    }

    @Test @MainActor func wideGroupHideWritesThenRefreshes() async throws {
        let fixture = try await wideCategoryFixture()
        await fixture.actions.setGroupHidden(true, group: fixture.group, month: "2026-07", using: fixture.state)
        let refreshed = try #require(
            fixture.viewport.snapshot(for: "2026-07")?.month.categoryGroups.first { $0.id == "group" }
        )
        #expect(BudgetCategoryVisibility.isHidden(refreshed.hidden))
    }

    @Test @MainActor func wideGroupHideRefusesAnIncomeGroupWithoutRefreshing() async throws {
        let fixture = try await wideCategoryFixture()
        let income = BudgetMonthCategoryGroup(
            id: "income", name: "Income", isIncome: true, hidden: false,
            budgeted: 0, spent: 0, balance: 0, categories: []
        )
        await fixture.actions.setGroupHidden(true, group: income, month: "2026-07", using: fixture.state)
        #expect(fixture.actions.errorMessage == "Income groups cannot be hidden.")
        #expect(!BudgetCategoryVisibility.isHidden(
            try #require(fixture.viewport.snapshot(for: "2026-07")?.month.categoryGroups.first { $0.id == "group" }).hidden
        ))
    }

    @Test @MainActor func wideGroupHideDoesNotWriteWhenTheSelectedBudgetIsNotTheVisibleOne() async throws {
        let fixture = try await wideCategoryFixture()
        fixture.state.settings.selectedBudgetID = "other-budget"
        await fixture.actions.setGroupHidden(true, group: fixture.group, month: "2026-07", using: fixture.state)
        let stored = try await fixture.store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        #expect(!BudgetCategoryVisibility.isHidden(
            try #require(stored.month.categoryGroups.first { $0.id == "group" }).hidden
        ))
    }

    @Test @MainActor func wideCarryoverTogglesFromTheMonthThenRefreshes() async throws {
        let fixture = try await wideCategoryFixture()
        let groceries = try #require(shownCategory("groceries", in: fixture.viewport))
        #expect(groceries.carryover)
        await fixture.actions.toggleCategoryCarryover(groceries, month: "2026-07", using: fixture.state)
        #expect(try #require(shownCategory("groceries", in: fixture.viewport)).carryover == false)
        #expect(fixture.actions.errorMessage == nil)
    }

    @Test @MainActor func wideCarryoverRefusesAnIncomeCategoryWithoutRefreshing() async throws {
        let fixture = try await wideCategoryFixture()
        let income = BudgetMonthCategory(
            id: "salary", name: "Salary", isIncome: true, hidden: false, groupID: "income",
            budgeted: 0, spent: 0, balance: 0, carryover: false
        )
        await fixture.actions.toggleCategoryCarryover(income, month: "2026-07", using: fixture.state)
        #expect(fixture.actions.errorMessage == "Rollover is only available for expense categories.")
        #expect(try #require(shownCategory("groceries", in: fixture.viewport)).carryover)
    }

    @Test @MainActor func wideCarryoverDoesNotWriteWhenTheSelectedBudgetIsNotTheVisibleOne() async throws {
        let fixture = try await wideCategoryFixture()
        let groceries = try #require(shownCategory("groceries", in: fixture.viewport))
        fixture.state.settings.selectedBudgetID = "other-budget"
        await fixture.actions.toggleCategoryCarryover(groceries, month: "2026-07", using: fixture.state)
        let stored = try await fixture.store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        #expect(try #require(stored.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }).carryover)
    }

    @Test @MainActor func wideDeleteOfAnUnusedCategoryDeletesAndRefreshes() async throws {
        let fixture = try await wideCategoryFixture()
        let copycat = try #require(shownCategory("copycat", in: fixture.viewport))
        await fixture.actions.requestDeleteCategory(copycat, using: fixture.state)
        #expect(shownCategory("copycat", in: fixture.viewport) == nil)
        #expect(fixture.actions.sheet == nil)
        #expect(fixture.actions.errorMessage == nil)
    }

    @Test @MainActor func wideDeleteOfACategoryWithTransactionsOpensTheTransferReview() async throws {
        let fixture = try await wideCategoryFixture()
        let groceries = try #require(shownCategory("groceries", in: fixture.viewport))
        await fixture.actions.requestDeleteCategory(groceries, using: fixture.state)
        #expect(fixture.actions.sheet == .categoryLifecycle(.deleteCategory(groceries)))
        #expect(fixture.actions.actionMonth == "2026-07")
        #expect(fixture.actions.actionBudgetID == "group-1")
        #expect(shownCategory("groceries", in: fixture.viewport) != nil)
    }

    @Test @MainActor func wideDeleteOfAnUnknownGroupFailsWithoutChangingTheViewport() async throws {
        let fixture = try await wideCategoryFixture()
        let ghost = BudgetMonthCategoryGroup(
            id: "ghost", name: "Ghost", isIncome: false, hidden: false,
            budgeted: 0, spent: 0, balance: 0, categories: []
        )
        await fixture.actions.requestDeleteGroup(ghost, using: fixture.state)
        #expect(fixture.actions.sheet == nil)
        #expect(fixture.viewport.snapshot(for: "2026-07")?.month.categoryGroups.contains { $0.id == "group" } == true)
    }
}
