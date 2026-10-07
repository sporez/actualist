import Foundation

/// Whether the server confirmed this flush's upload, shared with failover retries.
private actor UploadConfirmation {
    private(set) var isConfirmed = false
    func markConfirmed() { isConfirmed = true }
}

extension LocalFirstActualStore {
    enum PendingLocalMessageFlushOutcome {
        case succeeded, failed, cancelled
    }

    func requireSyncSession(database: BudgetDatabase, budgetID: String, generation: Int) throws {
        try Task.checkCancellation()
        guard generation == budgetSessionGeneration,
              self.database === database, openedBudgetID == budgetID else { throw CancellationError() }
    }

    private func ownsSyncSession(database: BudgetDatabase, budgetID: String, generation: Int) -> Bool {
        generation == budgetSessionGeneration && self.database === database && openedBudgetID == budgetID
    }

    /// `openBudget` replaces the direct open so the app can run it as a
    /// session transition; it returns whether a local baseline existed.
    func syncAndFindNewTransactions(
        budget: ActualBudget,
        serverURLString: String,
        openBudget: (@MainActor (ActualBudget) async throws -> Bool)? = nil
    ) async throws -> [BackgroundAccountRefreshResult] {
        if isDemoBudgetActive {
            // Demo mode never contacts a server and has no remote baseline to
            // diff against.
            return []
        }
        let hasLocalBaseline = if let openBudget {
            try await openBudget(budget)
        } else {
            try await openBudgetForBackgroundDiffIfNeeded(budget, serverURLString: serverURLString)
        }
        guard hasLocalBaseline else {
            return []
        }

        let budgetID = budget.syncID
        let refreshedDatabase = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let syncResult = try await pullAndReload(
            budgetID: budgetID,
            serverURLString: serverURLString
        )

        try requireSyncSession(database: refreshedDatabase, budgetID: budgetID, generation: generation)
        let accountDisplays: [AccountDisplay]
        if let cachedDisplays = accountsByBudget[budgetID] {
            accountDisplays = cachedDisplays
        } else {
            accountDisplays = try await refreshedDatabase.fetchAccountDisplays()
        }
        try requireSyncSession(database: refreshedDatabase, budgetID: budgetID, generation: generation)
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
        let generation = budgetSessionGeneration
        let pendingCount = (try? await database.pendingLocalSyncMessageCount()) ?? 0
        guard ownsSyncSession(database: database, budgetID: budgetID, generation: generation) else { return }
        if isDemoBudgetActive {
            // Demo mode keeps writes entirely local. CRDT application already
            // happened; drain the just-enqueued outbox rows so the pending count
            // stays at zero and no server round-trip is ever attempted.
            let drainedCount = (try? await database.drainAllPendingLocalSyncMessages()) ?? 0
            guard ownsSyncSession(database: database, budgetID: budgetID, generation: generation) else { return }
            await recordSyncStatus(budgetID: budgetID, uploadedCount: nil, appliedCount: nil, error: nil)
            guard ownsSyncSession(database: database, budgetID: budgetID, generation: generation) else { return }
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
        guard ownsSyncSession(database: database, budgetID: budgetID, generation: generation) else { return }
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
        let generation = budgetSessionGeneration
        repeat {
            for delay in pendingLocalMessageFlushRetryDelays {
                guard !Task.isCancelled,
                      ownsSyncSession(database: database, budgetID: budgetID, generation: generation),
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
            // A write that committed while this task was past the serialized
            // loop (in its reload/status tail) only set the flag, because the
            // task was still non-nil. Take another pass instead of clearing the
            // task, or that write waits for the next trigger.
        } while takeFlushRequestedDuringTail(
            database: database,
            budgetID: budgetID,
            generation: generation,
            serverURLString: serverURLString
        )
        if ownsSyncSession(database: database, budgetID: budgetID, generation: generation) {
            pendingLocalMessageFlushTask = nil
        }
    }

    /// Consumes `shouldFlushPendingLocalMessagesAgain` for a new scheduled pass.
    /// Clearing the flag on every call keeps a stale request from looping when
    /// the session, server or task no longer permits another pass.
    private func takeFlushRequestedDuringTail(
        database: BudgetDatabase,
        budgetID: String,
        generation: Int,
        serverURLString: String
    ) -> Bool {
        guard shouldFlushPendingLocalMessagesAgain else { return false }
        shouldFlushPendingLocalMessagesAgain = false
        return !Task.isCancelled
            && !isDemoBudgetActive
            && ownsSyncSession(database: database, budgetID: budgetID, generation: generation)
            && openedServerURLString == serverURLString
    }

    /// One flush attempt holds one background-execution assertion, released on
    /// completion, cancellation or expiration. Expiration cancels the attempt.
    /// Callers' backoff sleeps happen outside this method, so none is held then.
    func flushPendingLocalMessagesIfPossible(
        database: BudgetDatabase,
        budgetID: String,
        serverURLString: String
    ) async -> PendingLocalMessageFlushOutcome {
        let attempt = Task {
            await self.performFlushAttempt(
                database: database,
                budgetID: budgetID,
                serverURLString: serverURLString
            )
        }
        let assertion = backgroundExecution.begin(name: "Actualist outbox flush") { attempt.cancel() }
        defer { assertion.end() }
        return await withTaskCancellationHandler {
            await attempt.value
        } onCancel: {
            attempt.cancel()
        }
    }

    private func performFlushAttempt(
        database: BudgetDatabase,
        budgetID: String,
        serverURLString: String
    ) async -> PendingLocalMessageFlushOutcome {
        let generation = budgetSessionGeneration
        do {
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            let result = try await flushPendingLocalMessagesSerialized(
                database: database,
                budgetID: budgetID,
                serverURLString: serverURLString
            )
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            if result.appliedRemoteMessageCount > 0 {
                try await reloadAfterRemoteSync(database: database, budgetID: budgetID)
            }
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
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
            guard !error.isCancellation,
                  ownsSyncSession(database: database, budgetID: budgetID, generation: generation) else {
                return .cancelled
            }
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
        serverURLString: String,
        token: String? = nil
    ) async throws -> LocalFirstSyncResult {
        let generation = budgetSessionGeneration
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        while isFlushingPendingLocalMessages {
            shouldFlushPendingLocalMessagesAgain = true
            await waitForPendingLocalMessageFlushToFinish()
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        }

        isFlushingPendingLocalMessages = true
        defer {
            if ownsSyncSession(database: database, budgetID: budgetID, generation: generation) {
                isFlushingPendingLocalMessages = false
                resumePendingLocalMessageFlushWaiters()
            }
        }

        var totalResult = LocalFirstSyncResult(pushedMessageCount: 0, appliedRemoteMessageCount: 0)
        repeat {
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            shouldFlushPendingLocalMessagesAgain = false
            let result = try await flushPendingLocalMessages(
                database: database,
                budgetID: budgetID,
                serverURLString: serverURLString,
                token: token
            )
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            totalResult = LocalFirstSyncResult(
                pushedMessageCount: totalResult.pushedMessageCount + result.pushedMessageCount,
                appliedRemoteMessageCount: totalResult.appliedRemoteMessageCount + result.appliedRemoteMessageCount,
                insertedTransactionIDsByAccount: mergedTransactionIDsByAccount(
                    totalResult.insertedTransactionIDsByAccount,
                    result.insertedTransactionIDsByAccount
                ),
                quarantinedTimestamps: totalResult.quarantinedTimestamps + result.quarantinedTimestamps
            )
        } while shouldFlushPendingLocalMessagesAgain

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

    /// `token` is the sync token the calling operation already read; nil reads it
    /// here once pending messages exist.
    func flushPendingLocalMessages(
        database: BudgetDatabase,
        budgetID: String,
        serverURLString: String,
        token knownToken: String? = nil
    ) async throws -> LocalFirstSyncResult {
        let generation = budgetSessionGeneration
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        let pending = try await database.pendingLocalSyncMessages()
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        guard !pending.isEmpty else {
            return LocalFirstSyncResult(pushedMessageCount: 0, appliedRemoteMessageCount: 0)
        }
        let resolvedToken = try knownToken ?? keychain.readActualSyncToken()
        guard let token = resolvedToken else {
            throw LocalFirstError.missingSyncToken
        }
        var status = syncStatus ?? LocalFirstSyncStatus(fileID: budgetID, groupID: openedGroupID)
        status.lastSyncAttemptAt = Date()
        syncStatus = status
        let confirmation = UploadConfirmation()
        do {
            let result = try await withSyncFailover(serverURLString: serverURLString) { client in
                let sessionIsCurrent: @Sendable () async -> Bool = { [self] in
                    await ownsSyncSession(database: database, budgetID: budgetID, generation: generation)
                }
                // A failover retry after confirmation only pulls; it must not re-push.
                if await confirmation.isConfirmed {
                    let pull = try await self.syncClient.pullAndApply(
                        database: database,
                        client: client,
                        token: token,
                        sessionIsCurrent: sessionIsCurrent
                    )
                    return LocalFirstSyncResult(
                        pushedMessageCount: pending.count,
                        appliedRemoteMessageCount: pull.appliedMessageCount,
                        insertedTransactionIDsByAccount: pull.insertedTransactionIDsByAccount,
                        quarantinedTimestamps: pull.quarantinedTimestamps
                    )
                }
                return try await self.syncClient.pushAndPull(
                    database: database,
                    client: client,
                    token: token,
                    messages: pending.map(\.message),
                    since: pending.map(\.baseTimestamp).min(),
                    sessionIsCurrent: sessionIsCurrent,
                    onUploadConfirmed: { [self] in
                        // Delete the confirmed rows only while this session still owns the database.
                        try await requireSyncSession(
                            database: database, budgetID: budgetID, generation: generation
                        )
                        try await database.deletePendingLocalSyncMessages(pending)
                        await confirmation.markConfirmed()
                    }
                )
            }
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            recordQuarantinedSyncValues(result.quarantinedTimestamps)
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            let remainingCount = (try? await database.pendingLocalSyncMessageCount()) ?? 0
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            // One run uploads at most one batch (`pendingLocalSyncMessages(limit:)`).
            // Confirmed rows are deleted above, so any that remain are a later batch.
            if remainingCount > 0 {
                shouldFlushPendingLocalMessagesAgain = true
            }
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
                serverURLString: serverURLString,
                token: token
            )
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            // Confirmed rows were already deleted; this failure is a pull failure.
            if await !confirmation.isConfirmed {
                try? await database.markPendingLocalSyncMessagesFailed(pending, error: resolvedError)
            }
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            let remainingCount = (try? await database.pendingLocalSyncMessageCount()) ?? pending.count
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
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
        serverURLString: String,
        performsScheduleAdvancement: Bool = true
    ) async throws -> LocalFirstSyncResult {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        if isDemoBudgetActive {
            // Local-only: never touch transports. Reload caches from the local
            // database so a manual refresh still re-reads the local data.
            try await reloadAfterRemoteSync(database: database, budgetID: budgetID)
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            await recordSyncStatus(
                budgetID: budgetID,
                uploadedCount: 0,
                appliedCount: 0,
                error: nil
            )
            return LocalFirstSyncResult(pushedMessageCount: 0, appliedRemoteMessageCount: 0)
        }
        let token = try keychain.readActualSyncToken()
        guard let token else {
            throw LocalFirstError.missingSyncToken
        }
        var status = syncStatus ?? LocalFirstSyncStatus(fileID: budgetID, groupID: openedGroupID)
        status.lastSyncAttemptAt = Date()
        syncStatus = status
        do {
            let flushedResult = try await flushPendingLocalMessagesSerialized(
                database: database,
                budgetID: budgetID,
                serverURLString: serverURLString,
                token: token
            )
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            let pullResult = try await withSyncFailover(serverURLString: serverURLString) { client in
                try await self.syncClient.pullAndApply(
                    database: database,
                    client: client,
                    token: token,
                    sessionIsCurrent: { [self] in
                        await ownsSyncSession(
                            database: database, budgetID: budgetID, generation: generation
                        )
                    }
                )
            }
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            recordQuarantinedSyncValues(pullResult.quarantinedTimestamps)
            #if DEBUG
            print("[Actualist LocalFirst] Applied \(pullResult.appliedMessageCount) remote sync messages")
            #endif

            try await reloadAfterRemoteSync(database: database, budgetID: budgetID)
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            let result = LocalFirstSyncResult(
                pushedMessageCount: flushedResult.pushedMessageCount,
                appliedRemoteMessageCount: (
                    flushedResult.appliedRemoteMessageCount + pullResult.appliedMessageCount
                ),
                insertedTransactionIDsByAccount: mergedTransactionIDsByAccount(
                    flushedResult.insertedTransactionIDsByAccount,
                    pullResult.insertedTransactionIDsByAccount
                ),
                quarantinedTimestamps: flushedResult.quarantinedTimestamps + pullResult.quarantinedTimestamps
            )
            await recordSyncStatus(
                budgetID: budgetID,
                uploadedCount: result.pushedMessageCount,
                appliedCount: result.appliedRemoteMessageCount,
                error: nil
            )
            // Demo returns above. A failed pull throws above. Manual posting
            // passes false so this pull does not post the occurrence it is
            // about to write, and so advancement cannot re-enter this pull.
            if performsScheduleAdvancement {
                await advanceSchedulesAfterSuccessfulSync(
                    budgetID: budgetID,
                    database: database,
                    generation: generation
                )
            }
            return result
        } catch {
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            let resolvedError = await resolvedSyncFailure(
                error,
                serverURLString: serverURLString,
                token: token
            )
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
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
    private func resolvedSyncFailure(_ error: Error, serverURLString: String, token: String) async -> Error {
        guard case .syncRejected(_, let reason)? = error as? ActualAPIError else {
            return error
        }
        switch reason {
        case .fileHasNewKey:
            return LocalFirstError.budgetEncryptionChanged
        case .fileHasReset:
            let remoteIdentityDiffers = await remoteEncryptionIdentityDiffers(
                serverURLString: serverURLString,
                token: token
            )
            return remoteIdentityDiffers ? LocalFirstError.budgetEncryptionChanged : error
        case .fileOldVersion, .fileNeedsUpload, .fileKeyMismatch:
            return error
        }
    }

    /// `true` only when the live remote file metadata reports a different
    /// encryption key ID than the currently opened budget. An unknown file ID or
    /// failed lookup is treated as "no evidence of change" so the original
    /// server error is preserved.
    private func remoteEncryptionIdentityDiffers(serverURLString: String, token: String) async -> Bool {
        guard let fileID = await syncClient.configuration?.fileID else {
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
        let generation = budgetSessionGeneration
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        try await reloadSelectedBudgetCache(budgetID: budgetID)
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        invalidateReports(budgetID: budgetID)
        try await reloadAccountCaches(database: database, budgetID: budgetID)
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        let payees = try await database.fetchPayeeManagementSnapshot()
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        payeesByBudget[budgetID] = payees
            .settingCanUndo(lastPayeeUndoMessagesByBudget[budgetID]?.isEmpty == false)

        try await refreshLoadedTransactionFeedCaches(database: database, budgetID: budgetID)
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
    }

    /// Awaits first, then re-reads and replaces `syncStatus` in one synchronous
    /// step so concurrent calls cannot overwrite each other's fields. A pending
    /// count read that started before an already-landed newer read is dropped.
    func recordSyncStatus(
        budgetID: String,
        uploadedCount: Int?,
        appliedCount: Int?,
        error: Error?
    ) async {
        guard let database else { return }
        let generation = budgetSessionGeneration
        guard ownsSyncSession(database: database, budgetID: budgetID, generation: generation) else { return }
        syncStatusSequence &+= 1
        let sequence = syncStatusSequence
        let pendingCount = try? await database.pendingLocalSyncMessageCount()
        guard ownsSyncSession(database: database, budgetID: budgetID, generation: generation) else { return }
        var success: LocalFirstSyncStatusUpdate.Success?
        var errorDescription: String?
        if let appliedCount, let uploadedCount {
            let lastSyncedAt = Date()
            let usedFallback = lastSyncEndpoint == .fallback
            success = LocalFirstSyncStatusUpdate.Success(
                lastSyncedAt: lastSyncedAt,
                appliedCount: appliedCount,
                uploadedCount: uploadedCount,
                usedFallback: usedFallback
            )
            // The persisted checkpoint mirrors the merged counts, so compute them
            // from the current status without assigning it before the await.
            let counts = (syncStatus ?? LocalFirstSyncStatus(fileID: budgetID, groupID: openedGroupID))
                .merging(LocalFirstSyncStatusUpdate(
                    fileID: budgetID, groupID: openedGroupID, encryptionKeyID: nil,
                    pendingLocalMessageCount: nil, success: success, errorDescription: nil
                ))
            do {
                try await database.saveLocalSyncCheckpoint(
                    BudgetDatabase.LocalSyncCheckpoint(
                        lastSyncedAt: lastSyncedAt,
                        lastAppliedMessageCount: counts.lastAppliedMessageCount,
                        lastUploadedMessageCount: counts.lastUploadedMessageCount
                    )
                )
            } catch {
                #if DEBUG
                print("[Actualist LocalFirst] Could not persist the last sync checkpoint")
                #endif
            }
        } else if let error, !error.isCancellation {
            errorDescription = SafeSyncDiagnostic.description(for: error)
        }
        guard ownsSyncSession(database: database, budgetID: budgetID, generation: generation) else { return }
        let acceptsPendingCount = pendingCount != nil && sequence > appliedPendingCountSequence
        if acceptsPendingCount { appliedPendingCountSequence = sequence }
        syncStatus = (syncStatus ?? LocalFirstSyncStatus(fileID: budgetID, groupID: openedGroupID))
            .merging(LocalFirstSyncStatusUpdate(
                fileID: budgetID,
                groupID: openedGroupID,
                encryptionKeyID: openedEncryptionContext?.keyID,
                pendingLocalMessageCount: acceptsPendingCount ? pendingCount : nil,
                success: success,
                errorDescription: errorDescription
            ))
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
