import Foundation

extension LocalFirstActualStore {
    func cachedTransactions(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) -> LoadedAccountTransactions? {
        let key = TransactionFeedCacheKey(budgetID: budgetID, queryScope: scope, query: query)
        return transactionFeedPagesByKey[key]?.loaded
    }

    func refreshTransactions(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        let key = TransactionFeedCacheKey(budgetID: budgetID, queryScope: scope, query: query)
        try await refreshTransactionFeed(key: key, database: database)
    }

    func refreshTransactionFeed(
        key: TransactionFeedCacheKey,
        database: BudgetDatabase
    ) async throws {
        let ticket = transactionFeedRequestIdentity.begin(for: key)
        let limit = max(transactionFeedPagesByKey[key]?.nextOffset ?? transactionPageSize, transactionPageSize)
        let loaded = try await loadTransactionFeedPage(
            database: database,
            budgetID: key.budgetID,
            key: key,
            limit: limit,
            offset: 0
        )
        guard commitTransactionFeedPage(loaded, ticket: ticket, database: database, budgetID: key.budgetID) else {
            throw CancellationError()
        }
    }

    func loadOlderTransactions(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        let key = TransactionFeedCacheKey(budgetID: budgetID, queryScope: scope, query: query)
        try await loadOlderTransactionFeed(key: key, database: database)
    }

    func loadOlderTransactionFeed(
        key: TransactionFeedCacheKey,
        database: BudgetDatabase
    ) async throws {
        guard let current = transactionFeedPagesByKey[key] else {
            try await refreshTransactionFeed(key: key, database: database)
            return
        }
        guard !current.loaded.reachedEnd else { return }

        let ticket = transactionFeedRequestIdentity.begin(for: key)
        let older = try await loadTransactionFeedPage(
            database: database,
            budgetID: key.budgetID,
            key: key,
            limit: transactionPageSize,
            offset: current.nextOffset
        )
        guard transactionFeedRequestIdentity.accepts(ticket),
              self.database === database,
              openedBudgetID == key.budgetID,
              transactionFeedPagesByKey[key]?.nextOffset == current.nextOffset else {
            throw CancellationError()
        }
        transactionFeedPagesByKey[key] = TransactionFeedPage(
            loaded: current.loaded.appendingPage(older)
        )
    }

    func transactionPage(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        let database = try requireDatabase(for: budgetID)
        let sessionID = transactionFeedRequestIdentity.sessionID
        let key = TransactionFeedCacheKey(budgetID: budgetID, queryScope: scope, query: query)
        let loaded = try await loadTransactionFeedPage(
            database: database,
            budgetID: budgetID,
            key: key,
            limit: limit,
            offset: offset
        )
        guard transactionFeedRequestIdentity.sessionID == sessionID,
              self.database === database,
              openedBudgetID == budgetID else {
            throw CancellationError()
        }
        return loaded
    }

    func loadTransactionFeedPage(
        database: BudgetDatabase,
        budgetID: String,
        key: TransactionFeedCacheKey,
        limit: Int?,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        #if DEBUG
        try await testSeams?.transactionFeedPageReadHook?(key, key.query.text, limit, offset)
        #endif
        switch key.scope {
        case .account(let accountID):
            return try await loadedAccountTransactions(
                database: database,
                budgetID: budgetID,
                accountID: accountID,
                query: key.query,
                limit: limit,
                offset: offset
            )
        case .spending:
            return try await loadedSpendingTransactions(
                database: database,
                budgetID: budgetID,
                query: key.query,
                limit: limit,
                offset: offset
            )
        }
    }

    func commitTransactionFeedPage(
        _ loaded: LoadedAccountTransactions,
        ticket: TransactionFeedRequestIdentity.Ticket,
        database: BudgetDatabase,
        budgetID: String
    ) -> Bool {
        guard transactionFeedRequestIdentity.accepts(ticket),
              self.database === database,
              openedBudgetID == budgetID else { return false }
        transactionFeedPagesByKey[ticket.key] = TransactionFeedPage(loaded: loaded)
        return true
    }

    func loadedAccountTransactions(
        database: BudgetDatabase,
        budgetID: String,
        accountID: String,
        query: TransactionFeedQuery,
        limit: Int? = nil,
        offset: Int = 0
    ) async throws -> LoadedAccountTransactions {
        let maps = try await nameMaps(database)
        let accountPage = try await database.fetchAccountTransactionQueryPage(
            accountID: accountID,
            query: query,
            limit: limit,
            offset: offset
        )
        let page = accountPage.page
        return LoadedAccountTransactions(
            transactions: page.transactions,
            balance: accountPage.balance,
            accountNames: maps.accountNames,
            categoryNames: maps.categoryNames,
            payeeNames: maps.payeeNames,
            transferPayeeIDs: maps.transferPayeeIDs,
            transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
            offBudgetAccountIDs: maps.offBudgetAccountIDs,
            reachedEnd: page.reachedEnd,
            nextOffset: page.nextOffset,
            queryMetadata: TransactionQueryPageMetadata(
                totalMatchCount: page.totalMatchCount,
                querySignature: page.querySignature,
                matchingTransactionIDs: page.matchingTransactionIDs,
                contributingTransactionIDs: page.contributingTransactionIDs,
                attachedContextTransactionIDs: page.attachedContextTransactionIDs
            ),
            runningBalanceSetting: accountPage.runningBalanceSetting
        )
    }

    func loadedSpendingTransactions(
        database: BudgetDatabase,
        budgetID: String,
        query: TransactionFeedQuery,
        limit: Int? = nil,
        offset: Int = 0
    ) async throws -> LoadedAccountTransactions {
        let maps = try await nameMaps(database)
        let page = try await database.fetchTransactionQueryPage(
            scope: .spending,
            query: query,
            limit: limit,
            offset: offset
        )
        return LoadedAccountTransactions(
            transactions: page.transactions,
            balance: nil,
            accountNames: maps.accountNames,
            categoryNames: maps.categoryNames,
            payeeNames: maps.payeeNames,
            transferPayeeIDs: maps.transferPayeeIDs,
            transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
            offBudgetAccountIDs: maps.offBudgetAccountIDs,
            reachedEnd: page.reachedEnd,
            nextOffset: page.nextOffset,
            queryMetadata: TransactionQueryPageMetadata(
                totalMatchCount: page.totalMatchCount,
                querySignature: page.querySignature,
                matchingTransactionIDs: page.matchingTransactionIDs,
                contributingTransactionIDs: page.contributingTransactionIDs,
                attachedContextTransactionIDs: page.attachedContextTransactionIDs
            )
        )
    }
}
