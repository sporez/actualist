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
        let pendingCount = (try? await database.pendingLocalSyncMessageCount()) ?? 0
        await recordSyncStatus(budgetID: budgetID, uploadedCount: nil, appliedCount: nil, error: nil)
        recordSyncDebugEvent(
            outcome: .queued,
            pendingBefore: pendingCount,
            pendingAfter: pendingCount,
            message: pendingCount == 1 ? "Queued 1 local change" : "Queued \(pendingCount) local changes"
        )
        guard let serverURLString = openedServerURLString, !serverURLString.isEmpty else {
            return
        }
        if pendingLocalMessageFlushTask != nil || isFlushingPendingLocalMessages {
            shouldFlushPendingLocalMessagesAgain = true
            return
        }

        pendingLocalMessageFlushTask = Task { [weak self] in
            await self?.runScheduledPendingLocalMessageFlush(
                database: database,
                budgetID: budgetID,
                serverURLString: serverURLString
            )
        }
    }

    func runScheduledPendingLocalMessageFlush(
        database: BudgetDatabase,
        budgetID: String,
        serverURLString: String
    ) async {
        for delay in pendingLocalMessageFlushRetryDelays {
            guard !Task.isCancelled,
                  openedBudgetID == budgetID,
                  openedServerURLString == serverURLString else {
                break
            }
            if delay != .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    break
                }
            }
            if await flushPendingLocalMessagesIfPossible(
                database: database,
                budgetID: budgetID,
                serverURLString: serverURLString
            ) {
                break
            }
        }
        pendingLocalMessageFlushTask = nil
    }

    func flushPendingLocalMessagesIfPossible(
        database: BudgetDatabase,
        budgetID: String,
        serverURLString: String
    ) async -> Bool {
        do {
            let result = try await flushPendingLocalMessagesSerialized(
                database: database,
                budgetID: budgetID,
                serverURLString: serverURLString
            )
            if result.appliedRemoteMessageCount > 0 {
                try await reloadAfterRemoteSync(database: database, budgetID: budgetID)
            }
            if result.pushedMessageCount > 0 || result.appliedRemoteMessageCount > 0 {
                await recordSyncStatus(
                    budgetID: budgetID,
                    uploadedCount: result.pushedMessageCount,
                    appliedCount: result.appliedRemoteMessageCount,
                    error: nil
                )
            }
            return true
        } catch {
            await recordSyncStatus(
                budgetID: budgetID,
                uploadedCount: nil,
                appliedCount: nil,
                error: error
            )
            return false
        }
    }

    func flushPendingLocalMessagesSerialized(
        database: BudgetDatabase,
        budgetID: String,
        serverURLString: String
    ) async throws -> LocalFirstSyncResult {
        while isFlushingPendingLocalMessages {
            shouldFlushPendingLocalMessagesAgain = true
            await waitForPendingLocalMessageFlushToFinish()
        }

        isFlushingPendingLocalMessages = true
        defer {
            isFlushingPendingLocalMessages = false
            resumePendingLocalMessageFlushWaiters()
        }

        var totalResult = LocalFirstSyncResult(pushedMessageCount: 0, appliedRemoteMessageCount: 0)
        repeat {
            shouldFlushPendingLocalMessagesAgain = false
            let result = try await flushPendingLocalMessages(
                database: database,
                budgetID: budgetID,
                serverURLString: serverURLString
            )
            totalResult = LocalFirstSyncResult(
                pushedMessageCount: totalResult.pushedMessageCount + result.pushedMessageCount,
                appliedRemoteMessageCount: totalResult.appliedRemoteMessageCount + result.appliedRemoteMessageCount
            )
        } while shouldFlushPendingLocalMessagesAgain && openedBudgetID == budgetID

        return totalResult
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
    ) async throws -> LocalFirstSyncResult {
        let pending = try await database.pendingLocalSyncMessages()
        guard !pending.isEmpty else {
            return LocalFirstSyncResult(pushedMessageCount: 0, appliedRemoteMessageCount: 0)
        }
        let token = keychain.readActualSyncToken()
        guard !token.isEmpty else {
            throw LocalFirstError.missingSyncToken
        }
        guard let baseURL = URL(string: ActualServerURLNormalizer.normalize(serverURLString)) else {
            throw ActualAPIError.invalidURL
        }
        let client = syncTransportFactory(baseURL)
        var status = syncStatus ?? LocalFirstSyncStatus(fileID: budgetID, groupID: openedGroupID)
        status.lastSyncAttemptAt = Date()
        syncStatus = status
        do {
            let result = try await syncClient.pushAndPull(
                database: database,
                client: client,
                token: token,
                messages: pending.map(\.message),
                since: pending.map(\.baseTimestamp).min()
            )
            try await database.deletePendingLocalSyncMessages(pending)
            let remainingCount = (try? await database.pendingLocalSyncMessageCount()) ?? 0
            recordSyncDebugEvent(
                outcome: .succeeded,
                pendingBefore: pending.count,
                uploadedCount: result.pushedMessageCount,
                downloadedCount: result.appliedRemoteMessageCount,
                pendingAfter: remainingCount,
                message: "Server confirmed \(result.pushedMessageCount) uploaded sync message\(result.pushedMessageCount == 1 ? "" : "s")"
            )
            return result
        } catch {
            try? await database.markPendingLocalSyncMessagesFailed(pending, error: error)
            let remainingCount = (try? await database.pendingLocalSyncMessageCount()) ?? pending.count
            recordSyncDebugEvent(
                outcome: .failed,
                pendingBefore: pending.count,
                pendingAfter: remainingCount,
                message: error.localizedDescription
            )
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
        var status = syncStatus ?? LocalFirstSyncStatus(fileID: budgetID, groupID: openedGroupID)
        status.lastSyncAttemptAt = Date()
        syncStatus = status
        do {
            let flushedResult = try await flushPendingLocalMessagesSerialized(
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
            await recordSyncStatus(
                budgetID: budgetID,
                uploadedCount: flushedResult.pushedMessageCount,
                appliedCount: flushedResult.appliedRemoteMessageCount + appliedCount,
                error: nil
            )
        } catch {
            await recordSyncStatus(
                budgetID: budgetID,
                uploadedCount: nil,
                appliedCount: nil,
                error: error
            )
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

    func recordSyncStatus(
        budgetID: String,
        uploadedCount: Int?,
        appliedCount: Int?,
        error: Error?
    ) async {
        var status = syncStatus ?? LocalFirstSyncStatus(fileID: budgetID, groupID: openedGroupID)
        status.fileID = budgetID
        status.groupID = openedGroupID
        status.encryptionKeyID = openedEncryptionContext?.keyID
        if let database {
            status.pendingLocalMessageCount = (try? await database.pendingLocalSyncMessageCount()) ?? status.pendingLocalMessageCount
        }
        if let appliedCount, let uploadedCount {
            status.lastSyncedAt = Date()
            status.lastAppliedMessageCount = appliedCount
            if uploadedCount > 0 {
                status.lastUploadedMessageCount = uploadedCount
            }
            status.lastError = nil
        } else if let error {
            status.lastError = error.localizedDescription
        }
        syncStatus = status
    }

    func recordSyncDebugEvent(
        outcome: LocalFirstSyncDebugEvent.Outcome,
        pendingBefore: Int,
        uploadedCount: Int = 0,
        downloadedCount: Int = 0,
        pendingAfter: Int,
        message: String
    ) {
        syncDebugRecorder(
            LocalFirstSyncDebugEvent(
                id: UUID(),
                date: Date(),
                outcome: outcome,
                pendingBefore: pendingBefore,
                uploadedCount: uploadedCount,
                downloadedCount: downloadedCount,
                pendingAfter: pendingAfter,
                message: message
            )
        )
    }

    func retryPendingLocalMessageFlush() async {
        guard let database,
              let budgetID = openedBudgetID,
              let serverURLString = openedServerURLString,
              !serverURLString.isEmpty else {
            return
        }
        let pendingCount = (try? await database.pendingLocalSyncMessageCount()) ?? 0
        guard pendingCount > 0 else {
            return
        }
        _ = await flushPendingLocalMessagesIfPossible(
            database: database,
            budgetID: budgetID,
            serverURLString: serverURLString
        )
    }

}
