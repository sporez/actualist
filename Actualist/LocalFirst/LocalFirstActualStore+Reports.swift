import Foundation

extension LocalFirstActualStore {
    func cachedReportsDashboard(
        budgetID: String,
        range: ReportDateRange
    ) -> ReportsDashboardSnapshot? {
        reportsByKey[reportsKey(budgetID: budgetID, range: range)]
    }

    func refreshReportsDashboard(
        budgetID: String,
        range: ReportDateRange
    ) async throws -> ReportsDashboardSnapshot {
        let database = try requireDatabase(for: budgetID)
        let snapshot = try await database.fetchReportsDashboard(range: range)
        reportsByKey[reportsKey(budgetID: budgetID, range: range)] = snapshot
        return snapshot
    }

    func invalidateReports(budgetID: String? = nil) {
        guard let budgetID else {
            reportsByKey = [:]
            return
        }
        reportsByKey = reportsByKey.filter { !$0.key.hasPrefix("\(budgetID)|") }
    }

    private func reportsKey(budgetID: String, range: ReportDateRange) -> String {
        "\(budgetID)|\(range.cacheKey)"
    }
}
