import Foundation
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

    @Test func widgetFleetUsesLocalFinancialReadsWithoutReplacingScreenCaches() async throws {
        let database = try BudgetDatabase(databaseURL: makeSQLiteFixture())
        let store = makeStore()
        store.openedBudgetID = "group-1"
        store.database = database
        let loaded = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let now = try #require(ReportCalendar.date(fromDayID: "2026-08-15", calendar: ReportCalendar.gregorianLocal))
        let source = try await store.fetchWidgetSource(budgetID: "group-1", now: now)
        let accounts = try await database.fetchAccountDisplays()
        let transactions = try await database.fetchTransactionPage(limit: 16, splits: .grouped).transactions
        let reports = try await database.fetchReportsDashboard(range: .dashboard(through: now))
        #expect(source.accounts == accounts)
        #expect(source.recentTransactions == transactions)
        #expect(source.netWorth == reports.netWorth)
        #expect(source.month.month == "2026-08")
        #expect(source.attention != nil)
        #expect(store.cachedBudgetMonth(budgetID: "group-1") == loaded)
        #expect(store.cachedReportsDashboard(budgetID: "group-1", range: .dashboard(through: now)) == nil)
        #expect(store.cachedSpendingTransactions(budgetID: "group-1") == nil)
    }

}
