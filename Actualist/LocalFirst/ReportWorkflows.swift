import Foundation

/// Reports on the store: the dashboard cache read and refresh, explorer
/// snapshots and transaction drilldowns, and their session checks. The
/// store owns it; the dashboard cache (`reportsByKey`) and the shared
/// publication revision stay on the store, which publishes them.
@MainActor
final class ReportWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    func reportExplorerSessionIdentity(budgetID: String) -> ReportExplorerSessionIdentity {
        ReportExplorerSessionIdentity(
            budgetID: budgetID,
            generation: store.budgetSessionGeneration
        )
    }

    func cachedReportsDashboard(
        budgetID: String,
        range: ReportDateRange
    ) -> ReportsDashboardSnapshot? {
        store.reportsByKey[reportsKey(budgetID: budgetID, range: range)]
    }

    func refreshReportsDashboard(
        budgetID: String,
        range: ReportDateRange
    ) async throws -> ReportsDashboardSnapshot {
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let revision = store.cachePublicationRevision
        let snapshot = try await ReportDashboardSQL.fetchReportsDashboard(range: range, in: database)
        #if DEBUG
        await store.testSeams?.readPublicationHook?(.reportsDashboard)
        #endif
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        if revision == store.cachePublicationRevision {
            store.reportsByKey[reportsKey(budgetID: budgetID, range: range)] = snapshot
        }
        return snapshot
    }

    func reportExplorerSnapshot(
        budgetID: String,
        query: ReportExplorerQuery
    ) async throws -> ReportExplorerSnapshot {
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let snapshot = try await ReportExplorerSQL.fetchReportExplorer(query: query, in: database)
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
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let result = try await TransactionQuerySQL.fetchTransactionDrilldown(request, in: database)
        let maps = try await store.nameMaps(database)
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
        store.database === database
            && store.openedBudgetID == budgetID
            && store.budgetSessionGeneration == generation
    }

    func invalidateReports(budgetID: String? = nil) {
        store.cachePublicationRevision &+= 1
        guard let budgetID else {
            store.reportsByKey = [:]
            return
        }
        store.reportsByKey = store.reportsByKey.filter { !$0.key.hasPrefix("\(budgetID)|") }
    }

    private func reportsKey(budgetID: String, range: ReportDateRange) -> String {
        "\(budgetID)|\(range.cacheKey)"
    }
}

extension ReportWorkflows: ReportsRepositoryProtocol { }
