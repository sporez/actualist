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
        let loaded = LoadedBudgetMonth(
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
        // The confirmation sheet clears its binding before invoking apply.
        // Clearing the binding must preserve the captured assignment draft.
        actions.setConfirmation(nil)
        await actions.applyConfirmation(.category, using: appState)

        let recorded = try await repository.onlyTemplate()
        #expect(recorded.command == .category("mortgage"))
        #expect(recorded.budgetID == "file-1")
        #expect(recorded.month == "2026-06")
        #expect(viewport.snapshot(for: "2026-06") != nil)
    }
}
