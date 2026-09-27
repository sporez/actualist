import Foundation

extension LocalFirstActualStore {
    func reportExplorerSessionIdentity(budgetID: String) -> ReportExplorerSessionIdentity {
        ReportExplorerSessionIdentity(
            budgetID: budgetID,
            generation: budgetSessionGeneration
        )
    }

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

    func reportExplorerSnapshot(
        budgetID: String,
        query: ReportExplorerQuery
    ) async throws -> ReportExplorerSnapshot {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let snapshot = try await database.fetchReportExplorer(query: query)
        guard reportExplorerSessionIsCurrent(
            database: database,
            budgetID: budgetID,
            generation: generation
        ) else {
            throw CancellationError()
        }
        return snapshot
    }

    func reportExplorerSessionIsCurrent(
        database: BudgetDatabase,
        budgetID: String,
        generation: Int
    ) -> Bool {
        self.database === database
            && openedBudgetID == budgetID
            && budgetSessionGeneration == generation
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
