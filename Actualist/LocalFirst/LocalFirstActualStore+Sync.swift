import Foundation

extension LocalFirstActualStore {
    enum PendingLocalMessageFlushOutcome {
        case succeeded, failed, cancelled
    }

    func syncAndFindNewTransactions(
        budget: ActualBudget,
        serverURLString: String
    ) async throws -> [BackgroundAccountRefreshResult] {
        if isDemoBudgetActive {
            // Demo mode never contacts a server and has no remote baseline to
            // diff against.
            return []
        }
        let hasLocalBaseline = try await openBudgetForBackgroundDiffIfNeeded(
            budget,
            serverURLString: serverURLString
        )
        guard hasLocalBaseline else {
            return []
        }

        let budgetID = budget.syncID
        let syncResult = try await pullAndReload(
            budgetID: budgetID,
            serverURLString: serverURLString
        )

        let refreshedDatabase = try requireDatabase(for: budgetID)
        let accountDisplays: [AccountDisplay]
        if let cachedDisplays = accountsByBudget[budgetID] {
            accountDisplays = cachedDisplays
        } else {
            accountDisplays = try await refreshedDatabase.fetchAccountDisplays()
        }
        let accounts = accountDisplays.map(\.account).filter { !$0.closed }

        return accounts.compactMap { account in
            let newIDs = syncResult.insertedTransactionIDsByAccount[account.id] ?? []
            guard !newIDs.isEmpty else {
                return nil
            }
            return BackgroundAccountRefreshResult(account: account, newTransactionIDs: newIDs)
        }
    }

    func pendingLocalSyncMessageCount(budgetID: String) async throws -> Int {
        try await requireDatabase(for: budgetID).pendingLocalSyncMessageCount()
    }

    func schedulePendingLocalMessageFlush(database: BudgetDatabase, budgetID: String) async {
        let pendingCount = (try? await database.pendingLocalSyncMessageCount()) ?? 0
        if isDemoBudgetActive {
            // Demo mode keeps writes entirely local. CRDT application already
            // happened; drain the just-enqueued outbox rows so the pending count
            // stays at zero and no server round-trip is ever attempted.
            let drainedCount = (try? await database.drainAllPendingLocalSyncMessages()) ?? 0
            await recordSyncStatus(budgetID: budgetID, uploadedCount: nil, appliedCount: nil, error: nil)
            recordSyncDebugEvent(
                outcome: .queued,
                pendingBefore: pendingCount,
                pendingAfter: 0,
                message: drainedCount == 1
                    ? "Demo mode: 1 local change kept on device"
                    : "Demo mode: \(drainedCount) local changes kept on device"
            )
            return
        }
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
            ) != .failed {
                break
            }
        }
        pendingLocalMessageFlushTask = nil
    }

    func flushPendingLocalMessagesIfPossible(
        database: BudgetDatabase,
        budgetID: String,
        serverURLString: String
    ) async -> PendingLocalMessageFlushOutcome {
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
            return .succeeded
        } catch {
            guard !error.isCancellation else { return .cancelled }
            await recordSyncStatus(
                budgetID: budgetID,
                uploadedCount: nil,
                appliedCount: nil,
                error: error
            )
            return .failed
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
                appliedRemoteMessageCount: totalResult.appliedRemoteMessageCount + result.appliedRemoteMessageCount,
                insertedTransactionIDsByAccount: mergedTransactionIDsByAccount(
                    totalResult.insertedTransactionIDsByAccount,
                    result.insertedTransactionIDsByAccount
                )
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
        var status = syncStatus ?? LocalFirstSyncStatus(fileID: budgetID, groupID: openedGroupID)
        status.lastSyncAttemptAt = Date()
        syncStatus = status
        do {
            let result = try await withSyncFailover(serverURLString: serverURLString) { client in
                try await self.syncClient.pushAndPull(
                    database: database,
                    client: client,
                    token: token,
                    messages: pending.map(\.message),
                    since: pending.map(\.baseTimestamp).min()
                )
            }
            try await database.deletePendingLocalSyncMessages(pending)
            let remainingCount = (try? await database.pendingLocalSyncMessageCount()) ?? 0
            recordSyncDebugEvent(
                outcome: .succeeded,
                pendingBefore: pending.count,
                uploadedCount: result.pushedMessageCount,
                downloadedCount: result.appliedRemoteMessageCount,
                pendingAfter: remainingCount,
                message: "Server confirmed \(result.pushedMessageCount) uploaded sync message\(result.pushedMessageCount == 1 ? "" : "s")",
                endpoint: lastSyncEndpoint
            )
            return result
        } catch {
            guard !error.isCancellation else { throw error }
            let resolvedError = await resolvedSyncFailure(
                error,
                serverURLString: serverURLString
            )
            try? await database.markPendingLocalSyncMessagesFailed(pending, error: resolvedError)
            let remainingCount = (try? await database.pendingLocalSyncMessageCount()) ?? pending.count
            recordSyncDebugEvent(
                outcome: .failed,
                pendingBefore: pending.count,
                pendingAfter: remainingCount,
                message: SafeSyncDiagnostic.description(for: resolvedError),
                endpoint: lastSyncEndpoint
            )
            throw resolvedError
        }
    }

    // Preserve each transaction feed's loaded window when rebuilding caches.
    @discardableResult
    func pullAndReload(
        budgetID: String,
        serverURLString: String
    ) async throws -> LocalFirstSyncResult {
        if isDemoBudgetActive {
            // Local-only: never touch transports. Reload caches from the local
            // database so a manual refresh still re-reads the local data.
            let database = try requireDatabase(for: budgetID)
            try await reloadAfterRemoteSync(database: database, budgetID: budgetID)
            await recordSyncStatus(
                budgetID: budgetID,
                uploadedCount: 0,
                appliedCount: 0,
                error: nil
            )
            return LocalFirstSyncResult(pushedMessageCount: 0, appliedRemoteMessageCount: 0)
        }
        let token = keychain.readActualSyncToken()
        guard !token.isEmpty else {
            throw LocalFirstError.missingSyncToken
        }
        let database = try requireDatabase(for: budgetID)

        var status = syncStatus ?? LocalFirstSyncStatus(fileID: budgetID, groupID: openedGroupID)
        status.lastSyncAttemptAt = Date()
        syncStatus = status
        do {
            let flushedResult = try await flushPendingLocalMessagesSerialized(
                database: database,
                budgetID: budgetID,
                serverURLString: serverURLString
            )
            let pullResult = try await withSyncFailover(serverURLString: serverURLString) { client in
                try await self.syncClient.pullAndApply(
                    database: database,
                    client: client,
                    token: token
                )
            }
            #if DEBUG
            print("[Actualist LocalFirst] Applied \(pullResult.appliedMessageCount) remote sync messages")
            #endif

            try await reloadAfterRemoteSync(database: database, budgetID: budgetID)
            let result = LocalFirstSyncResult(
                pushedMessageCount: flushedResult.pushedMessageCount,
                appliedRemoteMessageCount: (
                    flushedResult.appliedRemoteMessageCount + pullResult.appliedMessageCount
                ),
                insertedTransactionIDsByAccount: mergedTransactionIDsByAccount(
                    flushedResult.insertedTransactionIDsByAccount,
                    pullResult.insertedTransactionIDsByAccount
                )
            )
            await recordSyncStatus(
                budgetID: budgetID,
                uploadedCount: result.pushedMessageCount,
                appliedCount: result.appliedRemoteMessageCount,
                error: nil
            )
            return result
        } catch {
            let resolvedError = await resolvedSyncFailure(
                error,
                serverURLString: serverURLString
            )
            await recordSyncStatus(
                budgetID: budgetID,
                uploadedCount: nil,
                appliedCount: nil,
                error: resolvedError
            )
            throw resolvedError
        }
    }

    /// Maps a raw sync failure onto the typed condition the UI needs. When the
    /// server refuses a sync because this budget's encryption identity changed,
    /// returns `LocalFirstError.budgetEncryptionChanged`; every other failure —
    /// including an unrelated HTTP 400, a plain server-side sync reset, or a
    /// transport error — is returned unchanged.
    ///
    /// Actual reports a key or group mismatch as a bare token in the 400 body.
    /// `file-has-new-key` is unambiguous: the `keyID` Actualist sent is not the
    /// file's registered key. `file-has-reset` only says the sync group changed,
    /// which Actual also does for a non-encryption reset, so it is confirmed
    /// against the live remote file metadata before being treated as an
    /// encryption change.
    private func resolvedSyncFailure(_ error: Error, serverURLString: String) async -> Error {
        guard case .syncRejected(_, let reason)? = error as? ActualAPIError else {
            return error
        }
        switch reason {
        case .fileHasNewKey:
            return LocalFirstError.budgetEncryptionChanged
        case .fileHasReset:
            let remoteIdentityDiffers = await remoteEncryptionIdentityDiffers(
                serverURLString: serverURLString
            )
            return remoteIdentityDiffers ? LocalFirstError.budgetEncryptionChanged : error
        case .fileOldVersion, .fileNeedsUpload, .fileKeyMismatch:
            return error
        }
    }

    /// `true` only when the live remote file metadata reports a different
    /// encryption key ID than the currently opened budget. A missing token,
    /// unknown file ID, or failed lookup is treated as "no evidence of change"
    /// so the original server error is preserved.
    private func remoteEncryptionIdentityDiffers(serverURLString: String) async -> Bool {
        guard let fileID = await syncClient.configuration?.fileID else {
            return false
        }
        let token = keychain.readActualSyncToken()
        guard !token.isEmpty else {
            return false
        }
        let remote: ActualSyncRemoteFile?
        do {
            remote = try await withConnectionFailover(serverURLString: serverURLString) { client in
                try await client.userFileInfo(fileID: fileID, token: token)
            }
        } catch {
            return false
        }
        guard let remote else {
            return false
        }
        return remote.syncEncryptionKeyID != openedEncryptionContext?.keyID
    }

    func mergedTransactionIDsByAccount(
        _ lhs: [String: [String]],
        _ rhs: [String: [String]]
    ) -> [String: [String]] {
        var merged = lhs.mapValues(Set.init)
        for (accountID, transactionIDs) in rhs {
            merged[accountID, default: []].formUnion(transactionIDs)
        }
        return merged.mapValues { $0.sorted() }
    }

    func reloadAfterRemoteSync(database: BudgetDatabase, budgetID: String) async throws {
        try await reloadSelectedBudgetCache(budgetID: budgetID)
        invalidateReports(budgetID: budgetID)
        try await reloadAccountCaches(database: database, budgetID: budgetID)
        payeesByBudget[budgetID] = try await database.fetchPayeeManagementSnapshot()
            .settingCanUndo(lastPayeeUndoMessagesByBudget[budgetID]?.isEmpty == false)

        try await refreshLoadedTransactionFeedCaches(database: database, budgetID: budgetID)
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
            let lastSyncedAt = Date()
            status.lastSyncedAt = lastSyncedAt
            status.lastAppliedMessageCount = appliedCount
            if uploadedCount > 0 {
                status.lastUploadedMessageCount = uploadedCount
            }
            status.lastError = nil
            status.lastSyncUsedFallback = (lastSyncEndpoint == .fallback)
            if let database {
                do {
                    try await database.saveLocalSyncCheckpoint(
                        BudgetDatabase.LocalSyncCheckpoint(
                            lastSyncedAt: lastSyncedAt,
                            lastAppliedMessageCount: status.lastAppliedMessageCount,
                            lastUploadedMessageCount: status.lastUploadedMessageCount
                        )
                    )
                } catch {
                    #if DEBUG
                    print("[Actualist LocalFirst] Could not persist the last sync checkpoint")
                    #endif
                }
            }
        } else if let error, !error.isCancellation {
            status.lastError = SafeSyncDiagnostic.description(for: error)
        }
        syncStatus = status
    }

    func recordSyncDebugEvent(
        outcome: LocalFirstSyncDebugEvent.Outcome,
        pendingBefore: Int,
        uploadedCount: Int = 0,
        downloadedCount: Int = 0,
        pendingAfter: Int,
        message: String,
        endpoint: LocalFirstSyncDebugEvent.Endpoint? = nil
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
                message: message,
                endpoint: endpoint
            )
        )
    }

    func retryPendingLocalMessageFlush() async {
        if isDemoBudgetActive {
            // Nothing to retry: the outbox is drained on every demo write.
            return
        }
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
