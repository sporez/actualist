import Foundation

@MainActor
protocol ReportsRepositoryProtocol: AnyObject {
    func cachedReportsDashboard(
        budgetID: String,
        range: ReportDateRange
    ) -> ReportsDashboardSnapshot?

    func refreshReportsDashboard(
        budgetID: String,
        range: ReportDateRange
    ) async throws -> ReportsDashboardSnapshot

    func reportExplorerSnapshot(
        budgetID: String,
        query: ReportExplorerQuery
    ) async throws -> ReportExplorerSnapshot
}
