import GRDB
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func uncachedWidgetMonthReadDoesNotReplaceBudgetScreenCache() async throws {
        let database = try BudgetDatabase(databaseURL: makeSQLiteFixture())
        let store = makeStore()
        store.openedBudgetID = "group-1"
        store.database = database
        let loaded = try await store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-07"
        )

        let widgetSource = try await store.fetchBudgetMonthUncached(
            budgetID: "group-1",
            month: "2026-08"
        )

        #expect(widgetSource.month.month == "2026-08")
        #expect(widgetSource.currency == loaded.currency)
        #expect(store.cachedBudgetMonth(budgetID: "group-1") == loaded)
    }
}
