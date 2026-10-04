import Foundation
import Testing
@testable import Actualist

/// The dashboard cards and the explorer compute spending through different
/// read paths (SQL aggregation versus drilldown contributors) but must agree
/// on the same on-budget fixture, including refunds, split children,
/// uncategorized on-budget transfer sides, and excluded off-budget rows.
@Suite("Report spending equivalence")
struct ReportSpendingEquivalenceTests {
    @Test func dashboardAndExplorerAgreeOnSpendingForTheSameFixture() async throws {
        let database = try BudgetDatabase(databaseURL: ReportExplorerTests().makeFixture())
        let range = ReportDateRange(anchorMonth: "2026-01", startDay: "2025-08-01", endDay: "2026-01-23")
        let dashboard = try await database.fetchReportsDashboard(range: range)
        let explorer = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .spending,
            startDay: "2026-01-01",
            endDay: "2026-01-23",
            interval: .day
        ))

        #expect(explorer.points.count == 23)
        let explorerCumulative = explorer.points.map(\.expenses).reduce(into: [Int]()) { result, value in
            result.append((result.last ?? 0) + value)
        }
        #expect(explorerCumulative.last == 11_000)
        #expect(dashboard.budgetOverview.actualPoints.map(\.value) == explorerCumulative)
        #expect(dashboard.budgetOverview.actualExpenses == explorer.totals.expenses)
        #expect(dashboard.monthComparison.points[22].current == explorer.totals.expenses)
        #expect(dashboard.threeMonthAverage.currentExpenses == explorer.totals.expenses)
    }
}
