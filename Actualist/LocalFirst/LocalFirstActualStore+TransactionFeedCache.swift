import Foundation

extension LocalFirstActualStore {
    /// Refresh all cached account pages and Spending as one publication. A newer
    /// read for any member invalidates the whole candidate so a mutation cannot
    /// leave a partly old collection of observed filters.
    func refreshLoadedTransactionFeedCaches(
        database: BudgetDatabase,
        budgetID: String,
        accountIDs: Set<String>? = nil
    ) async throws {
        await transactionFeedCacheRefreshGate.acquire()
        defer { transactionFeedCacheRefreshGate.release() }

        while true {
            try Task.checkCancellation()
            guard self.database === database, openedBudgetID == budgetID else {
                throw CancellationError()
            }
            var keys = Set(transactionFeedPagesByKey.keys.filter { $0.budgetID == budgetID })
            keys.formUnion(transactionFeedRequestIdentity.keys(forBudget: budgetID))
            if let accountIDs {
                keys.formUnion(accountIDs.map { .account(budgetID: budgetID, accountID: $0) })
            }
            let orderedKeys = keys.sorted(by: transactionFeedCacheKeyOrder)
            let sessionID = transactionFeedRequestIdentity.sessionID
            let tickets = orderedKeys.map { transactionFeedRequestIdentity.begin(for: $0) }
            var refreshedPages: [TransactionFeedCacheKey: TransactionFeedPage] = [:]
            var retryForSupersedingRead = false

            for (key, ticket) in zip(orderedKeys, tickets) {
                try Task.checkCancellation()
                let previous = transactionFeedPagesByKey[key]
                let limit = max(previous?.nextOffset ?? transactionPageSize, transactionPageSize)
                let loaded = try await loadTransactionFeedPage(
                    database: database,
                    budgetID: budgetID,
                    key: key,
                    query: nil,
                    limit: limit,
                    offset: 0
                )
                try Task.checkCancellation()
                guard transactionFeedRequestIdentity.sessionID == sessionID,
                      self.database === database,
                      openedBudgetID == budgetID else {
                    throw CancellationError()
                }
                guard transactionFeedRequestIdentity.accepts(ticket) else {
                    retryForSupersedingRead = true
                    break
                }
                refreshedPages[key] = TransactionFeedPage(loaded: loaded)
            }

            if retryForSupersedingRead || !transactionFeedRequestIdentity.accepts(tickets) {
                continue
            }
            guard transactionFeedRequestIdentity.sessionID == sessionID,
                  self.database === database,
                  openedBudgetID == budgetID else {
                throw CancellationError()
            }
            transactionFeedPagesByKey.merge(refreshedPages) { _, refreshed in refreshed }
            return
        }
    }

    func transactionFeedCacheKeyOrder(
        _ lhs: TransactionFeedCacheKey,
        _ rhs: TransactionFeedCacheKey
    ) -> Bool {
        let lhsScope = transactionFeedScopeOrder(lhs.scope)
        let rhsScope = transactionFeedScopeOrder(rhs.scope)
        if lhsScope != rhsScope { return lhsScope < rhsScope }
        return lhs.statusFilter.rawValue < rhs.statusFilter.rawValue
    }

    func transactionFeedScopeOrder(_ scope: TransactionFeedCacheScope) -> String {
        switch scope {
        case .account(let accountID): "account|\(accountID)"
        case .spending: "spending"
        }
    }
}
