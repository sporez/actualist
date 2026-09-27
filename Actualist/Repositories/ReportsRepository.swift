import Foundation

@MainActor
protocol ReportsRepositoryProtocol: AnyObject {
    func reportExplorerSessionIdentity(budgetID: String) -> ReportExplorerSessionIdentity

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

extension ReportsRepositoryProtocol {
    func reportExplorerSessionIdentity(budgetID: String) -> ReportExplorerSessionIdentity {
        ReportExplorerSessionIdentity(budgetID: budgetID, generation: 0)
    }
}
