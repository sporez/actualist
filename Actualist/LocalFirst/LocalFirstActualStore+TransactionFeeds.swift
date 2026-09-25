import Foundation

extension LocalFirstActualStore {
    func cachedAccountTransactions(
        budgetID: String,
        accountID: String,
        statusFilter: TransactionStatusFilter = .all
    ) -> LoadedAccountTransactions? {
        transactionFeedPagesByKey[.account(
            budgetID: budgetID, accountID: accountID, statusFilter: statusFilter
        )]?.loaded
    }

    func cachedSpendingTransactions(
        budgetID: String,
        statusFilter: TransactionStatusFilter = .all
    ) -> LoadedAccountTransactions? {
        transactionFeedPagesByKey[.spending(budgetID: budgetID, statusFilter: statusFilter)]?.loaded
    }

    func refreshAccountTransactions(
        budgetID: String,
        accountID: String,
        statusFilter: TransactionStatusFilter = .all
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        try await refreshTransactionFeed(
            key: .account(budgetID: budgetID, accountID: accountID, statusFilter: statusFilter),
            database: database
        )
    }

    func refreshSpendingTransactions(
        budgetID: String,
        statusFilter: TransactionStatusFilter = .all
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        try await refreshTransactionFeed(
            key: .spending(budgetID: budgetID, statusFilter: statusFilter),
            database: database
        )
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
            query: nil,
            limit: limit,
            offset: 0
        )
        guard commitTransactionFeedPage(loaded, ticket: ticket, database: database, budgetID: key.budgetID) else {
            throw CancellationError()
        }
    }

    func loadOlderTransactions(
        budgetID: String,
        accountID: String,
        statusFilter: TransactionStatusFilter = .all
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        try await loadOlderTransactionFeed(
            key: .account(budgetID: budgetID, accountID: accountID, statusFilter: statusFilter),
            database: database
        )
    }

    func loadOlderSpendingTransactions(
        budgetID: String,
        statusFilter: TransactionStatusFilter = .all
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        try await loadOlderTransactionFeed(
            key: .spending(budgetID: budgetID, statusFilter: statusFilter),
            database: database
        )
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
            query: nil,
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

    func searchAccountTransactions(
        budgetID: String,
        accountID: String,
        query: String,
        limit: Int,
        offset: Int,
        statusFilter: TransactionStatusFilter = .all
    ) async throws -> LoadedAccountTransactions {
        let database = try requireDatabase(for: budgetID)
        let sessionID = transactionFeedRequestIdentity.sessionID
        let loaded = try await loadTransactionFeedPage(
            database: database,
            budgetID: budgetID,
            key: .account(budgetID: budgetID, accountID: accountID, statusFilter: statusFilter),
            query: query,
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

    func searchSpendingTransactions(
        budgetID: String,
        query: String,
        limit: Int,
        offset: Int,
        statusFilter: TransactionStatusFilter = .all
    ) async throws -> LoadedAccountTransactions {
        let database = try requireDatabase(for: budgetID)
        let sessionID = transactionFeedRequestIdentity.sessionID
        let loaded = try await loadTransactionFeedPage(
            database: database,
            budgetID: budgetID,
            key: .spending(budgetID: budgetID, statusFilter: statusFilter),
            query: query,
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
        query: String?,
        limit: Int?,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        try await transactionFeedPageReadHook?(key, query, limit, offset)
        switch key.scope {
        case .account(let accountID):
            return try await loadedAccountTransactions(
                database: database,
                budgetID: budgetID,
                accountID: accountID,
                query: query,
                limit: limit,
                offset: offset,
                statusFilter: key.statusFilter
            )
        case .spending:
            return try await loadedSpendingTransactions(
                database: database,
                budgetID: budgetID,
                query: query,
                limit: limit,
                offset: offset,
                statusFilter: key.statusFilter
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
        query: String?,
        limit: Int? = nil,
        offset: Int = 0,
        statusFilter: TransactionStatusFilter = .all
    ) async throws -> LoadedAccountTransactions {
        let maps = try await nameMaps(database)
        let balance = accountsByBudget[budgetID]?.first(where: { $0.account.id == accountID })?.balance
        let page = try await database.fetchTransactionPage(
            accountID: accountID,
            matching: query,
            limit: limit,
            offset: offset,
            statusFilter: statusFilter
        )
        return LoadedAccountTransactions(
            transactions: page.transactions,
            balance: balance,
            accountNames: maps.accountNames,
            categoryNames: maps.categoryNames,
            payeeNames: maps.payeeNames,
            transferPayeeIDs: maps.transferPayeeIDs,
            transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
            offBudgetAccountIDs: maps.offBudgetAccountIDs,
            reachedEnd: page.reachedEnd,
            nextOffset: page.nextOffset
        )
    }

    func loadedSpendingTransactions(
        database: BudgetDatabase,
        budgetID: String,
        query: String?,
        limit: Int? = nil,
        offset: Int = 0,
        statusFilter: TransactionStatusFilter = .all
    ) async throws -> LoadedAccountTransactions {
        let maps = try await nameMaps(database)
        let page = try await database.fetchTransactionPage(
            matching: query,
            limit: limit,
            offset: offset,
            statusFilter: statusFilter
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
            nextOffset: page.nextOffset
        )
    }

}
