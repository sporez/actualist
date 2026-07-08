import Foundation

extension LocalFirstActualStore {
    func syncAndFindNewTransactions(
        budget: ActualBudget,
        serverURLString: String
    ) async throws -> [BackgroundAccountRefreshResult] {
        let hasLocalBaseline = try await openBudgetForBackgroundDiffIfNeeded(
            budget,
            serverURLString: serverURLString
        )
        guard hasLocalBaseline else {
            return []
        }

        let budgetID = budget.syncID
        let database = try requireDatabase(for: budgetID)
        let transactionIDsBeforeSync = try await transactionIDsByAccount(database: database)

        try await pullAndReload(budgetID: budgetID, serverURLString: serverURLString)

        let refreshedDatabase = try requireDatabase(for: budgetID)
        let transactionIDsAfterSync = try await transactionIDsByAccount(database: refreshedDatabase)
        let accountDisplays: [AccountDisplay]
        if let cachedDisplays = accountsByBudget[budgetID] {
            accountDisplays = cachedDisplays
        } else {
            accountDisplays = try await refreshedDatabase.fetchAccountDisplays()
        }
        let accounts = accountDisplays.map(\.account).filter { !$0.closed }

        return accounts.compactMap { account in
            let previousIDs = transactionIDsBeforeSync[account.id] ?? []
            let currentIDs = transactionIDsAfterSync[account.id] ?? []
            let newIDs = currentIDs.subtracting(previousIDs).sorted()
            guard !newIDs.isEmpty else {
                return nil
            }
            return BackgroundAccountRefreshResult(account: account, newTransactionIDs: newIDs)
        }
    }

    func transactionIDsByAccount(database: BudgetDatabase) async throws -> [String: Set<String>] {
        try await database.fetchTransactions().reduce(into: [:]) { idsByAccount, transaction in
            insertTransactionID(transaction, into: &idsByAccount)
            for child in transaction.subtransactions {
                insertTransactionID(child, into: &idsByAccount)
            }
        }
    }

    func insertTransactionID(
        _ transaction: ActualTransaction,
        into idsByAccount: inout [String: Set<String>]
    ) {
        guard let id = transaction.id, !id.isEmpty, !transaction.account.isEmpty else {
            return
        }
        idsByAccount[transaction.account, default: []].insert(id)
    }

    func pendingLocalSyncMessageCount(budgetID: String) async throws -> Int {
        try await requireDatabase(for: budgetID).pendingLocalSyncMessageCount()
    }

    func schedulePendingLocalMessageFlush(database: BudgetDatabase, budgetID: String) async {
        await recordSyncStatus(budgetID: budgetID, appliedCount: nil, error: nil)
        guard let serverURLString = openedServerURLString, !serverURLString.isEmpty else {
            return
        }
        if isFlushingPendingLocalMessages {
            shouldFlushPendingLocalMessagesAgain = true
            return
        }
        Task { [weak self] in
            await self?.flushPendingLocalMessagesIfPossible(
                database: database,
                budgetID: budgetID,
                serverURLString: serverURLString
            )
        }
    }

    func flushPendingLocalMessagesIfPossible(
        database: BudgetDatabase,
        budgetID: String,
        serverURLString: String
    ) async {
        do {
            let appliedCount = try await flushPendingLocalMessagesSerialized(
                database: database,
                budgetID: budgetID,
                serverURLString: serverURLString
            )
            if appliedCount > 0 {
                try await reloadAfterRemoteSync(database: database, budgetID: budgetID)
            }
            await recordSyncStatus(budgetID: budgetID, appliedCount: appliedCount, error: nil)
        } catch {
            await recordSyncStatus(budgetID: budgetID, appliedCount: nil, error: error)
        }
    }

    func flushPendingLocalMessagesSerialized(
        database: BudgetDatabase,
        budgetID: String,
        serverURLString: String
    ) async throws -> Int {
        while isFlushingPendingLocalMessages {
            shouldFlushPendingLocalMessagesAgain = true
            await waitForPendingLocalMessageFlushToFinish()
        }

        isFlushingPendingLocalMessages = true
        defer {
            isFlushingPendingLocalMessages = false
            resumePendingLocalMessageFlushWaiters()
        }

        var totalAppliedCount = 0
        repeat {
            shouldFlushPendingLocalMessagesAgain = false
            totalAppliedCount += try await flushPendingLocalMessages(
                database: database,
                budgetID: budgetID,
                serverURLString: serverURLString
            )
        } while shouldFlushPendingLocalMessagesAgain && openedBudgetID == budgetID

        return totalAppliedCount
    }

    func waitForPendingLocalMessageFlushToFinish() async {
        await withCheckedContinuation { continuation in
            pendingLocalMessageFlushWaiters.append(continuation)
        }
    }

    func resumePendingLocalMessageFlushWaiters() {
        let waiters = pendingLocalMessageFlushWaiters
        pendingLocalMessageFlushWaiters = []
        waiters.forEach { $0.resume() }
    }

    func flushPendingLocalMessages(
        database: BudgetDatabase,
        budgetID: String,
        serverURLString: String
    ) async throws -> Int {
        let pending = try await database.pendingLocalSyncMessages()
        guard !pending.isEmpty else {
            return 0
        }
        let token = keychain.readActualSyncToken()
        guard !token.isEmpty else {
            throw LocalFirstError.missingSyncToken
        }
        guard let baseURL = URL(string: ActualServerURLNormalizer.normalize(serverURLString)) else {
            throw ActualAPIError.invalidURL
        }
        let client = syncTransportFactory(baseURL)
        do {
            let result = try await syncClient.pushAndPull(
                database: database,
                client: client,
                token: token,
                messages: pending.map(\.message),
                since: pending.map(\.baseTimestamp).min()
            )
            try await database.deletePendingLocalSyncMessages(pending)
            return result.appliedRemoteMessageCount
        } catch {
            try? await database.markPendingLocalSyncMessagesFailed(pending, error: error)
            throw error
        }
    }

    /// Pull remote CRDT messages, apply them, then reload native read caches so they are
    /// authoritative after any refresh. Transaction feeds preserve their loaded windows rather
    /// than falling back to full-history loads.
    func pullAndReload(budgetID: String, serverURLString: String) async throws {
        let token = keychain.readActualSyncToken()
        guard !token.isEmpty else {
            throw LocalFirstError.missingSyncToken
        }
        guard let baseURL = URL(string: ActualServerURLNormalizer.normalize(serverURLString)) else {
            throw ActualAPIError.invalidURL
        }
        let database = try requireDatabase(for: budgetID)

        let client = syncTransportFactory(baseURL)
        do {
            let flushedAppliedCount = try await flushPendingLocalMessagesSerialized(
                database: database,
                budgetID: budgetID,
                serverURLString: serverURLString
            )
            let appliedCount = try await syncClient.pullAndApply(
                database: database,
                client: client,
                token: token
            )
            #if DEBUG
            print("[Actualist LocalFirst] Applied \(appliedCount) remote sync messages for \(budgetID)")
            #endif

            try await reloadAfterRemoteSync(database: database, budgetID: budgetID)
            await recordSyncStatus(budgetID: budgetID, appliedCount: flushedAppliedCount + appliedCount, error: nil)
        } catch {
            await recordSyncStatus(budgetID: budgetID, appliedCount: nil, error: error)
            throw error
        }
    }

    func reloadAfterRemoteSync(database: BudgetDatabase, budgetID: String) async throws {
        monthsByBudget[budgetID] = nil
        accountsByBudget[budgetID] = try await database.fetchAccountDisplays()

        let prefix = "\(budgetID)|"
        for (key, page) in Array(accountTransactionsByKey) where key.hasPrefix(prefix) {
            let accountID = String(key.dropFirst(prefix.count))
            let limit = max(page.nextOffset, transactionPageSize)
            accountTransactionsByKey[key] = TransactionFeedPage(
                loaded: try await loadedAccountTransactions(
                    database: database,
                    budgetID: budgetID,
                    accountID: accountID,
                    query: nil,
                    limit: limit,
                    offset: 0
                )
            )
        }

        if let currentSpending = spendingTransactionsByBudget[budgetID] {
            let limit = max(currentSpending.nextOffset, transactionPageSize)
            spendingTransactionsByBudget[budgetID] = TransactionFeedPage(
                loaded: try await loadedSpendingTransactions(
                    database: database,
                    budgetID: budgetID,
                    query: nil,
                    limit: limit,
                    offset: 0
                )
            )
        }
    }

    func recordSyncStatus(budgetID: String, appliedCount: Int?, error: Error?) async {
        var status = syncStatus ?? LocalFirstSyncStatus(fileID: budgetID, groupID: openedGroupID)
        status.fileID = budgetID
        status.groupID = openedGroupID
        status.encryptionKeyID = openedEncryptionContext?.keyID
        if let database {
            status.pendingLocalMessageCount = (try? await database.pendingLocalSyncMessageCount()) ?? status.pendingLocalMessageCount
        }
        if let appliedCount {
            status.lastSyncedAt = Date()
            status.lastAppliedMessageCount = appliedCount
            status.lastError = nil
        } else {
            status.lastError = error?.localizedDescription
        }
        syncStatus = status
    }

}
