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
        let generation = budgetSessionGeneration
        let revision = cachePublicationRevision
        let snapshot = try await database.fetchReportsDashboard(range: range)
        #if DEBUG
        await testSeams?.readPublicationHook?(.reportsDashboard)
        #endif
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        if revision == cachePublicationRevision {
            reportsByKey[reportsKey(budgetID: budgetID, range: range)] = snapshot
        }
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

    func reportTransactionDrilldown(
        budgetID: String,
        request: TransactionDrilldownRequest
    ) async throws -> ReportTransactionDrilldownSnapshot {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let result = try await database.fetchTransactionDrilldown(request)
        let maps = try await nameMaps(database)
        guard reportExplorerSessionIsCurrent(
            database: database,
            budgetID: budgetID,
            generation: generation
        ) else {
            throw CancellationError()
        }
        let contributingIDs = Set(result.contributingTransactions.compactMap(\.id))
        let loaded = LoadedAccountTransactions(
            transactions: result.displayTransactions,
            balance: nil,
            accountNames: maps.accountNames,
            categoryNames: maps.categoryNames,
            payeeNames: maps.payeeNames,
            transferPayeeIDs: maps.transferPayeeIDs,
            transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
            offBudgetAccountIDs: maps.offBudgetAccountIDs,
            reachedEnd: true,
            queryMetadata: TransactionQueryPageMetadata(
                totalMatchCount: result.totalMatchCount,
                querySignature: result.querySignature,
                matchingTransactionIDs: result.matchingTransactionIDs,
                contributingTransactionIDs: contributingIDs,
                attachedContextTransactionIDs: result.attachedContextTransactionIDs
            )
        )
        return ReportTransactionDrilldownSnapshot(
            request: request,
            loaded: loaded,
            contributingTransactionIDs: contributingIDs
        )
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
        cachePublicationRevision &+= 1
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
