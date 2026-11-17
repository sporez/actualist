import Foundation

/// The launch snapshot and the post-presentation warmup on the store: the
/// first Budget frame restored from the sidecar, its compare-and-write
/// refresh, and the account, payee, diagnostic and sync-status caches read
/// after the Budget is on screen. The store owns it; the snapshot files,
/// context and written revision stay on the store, which sets them on open
/// and clears them on `closeOpenBudget`.
@MainActor
final class BudgetLaunchWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    /// Restores the first Budget frame from the sidecar when every persistent
    /// identity still matches. A cache failure is only a miss; the caller keeps
    /// the existing live projection fallback.
    func seedBudgetForLaunch(
        database: BudgetDatabase,
        files: BudgetLaunchSnapshotFiles,
        metadata: LocalFirstBudgetMetadata,
        budgetID: String,
        preferredCalendarMonth: String
    ) async {
        let revision: UInt64?
        do {
            revision = try await LaunchSignpost.measure(LaunchStage.launchSnapshotRevisionRead) {
                try await files.loadRevision()
            }
        } catch {
            LaunchSignpost.event(LaunchStage.launchSnapshotMiss)
            await seedBudgetFromLiveProjection(
                database: database,
                files: files,
                metadata: metadata,
                budgetID: budgetID,
                preferredCalendarMonth: preferredCalendarMonth,
                expectedRevision: nil
            )
            return
        }

        let stored: BudgetLaunchSnapshot?
        do {
            let pair = try await LaunchSignpost.measure(LaunchStage.launchSnapshotRead) {
                try await files.loadRevisionAndSnapshot()
            }
            guard pair.revision == revision else {
                LaunchSignpost.event(LaunchStage.launchSnapshotMiss)
                await seedBudgetFromLiveProjection(
                    database: database,
                    files: files,
                    metadata: metadata,
                    budgetID: budgetID,
                    preferredCalendarMonth: preferredCalendarMonth,
                    expectedRevision: pair.revision
                )
                return
            }
            stored = pair.snapshot
        } catch {
            stored = nil
        }

        let modeIdentity = try? await BudgetModeSQL.fetchBudgetModeIdentity(in: database)
        #if DEBUG
        await store.testSeams?.readPublicationHook?(.launchSeed)
        #endif
        guard !Task.isCancelled, store.database === database, store.openedBudgetID == budgetID else { return }
        // A write that advanced the persistent revision while the snapshot was
        // being read makes it stale: fall through to the live projection.
        let currentRevision = try? await files.loadRevision()
        guard !Task.isCancelled, store.database === database, store.openedBudgetID == budgetID else { return }
        if let revision, currentRevision == revision,
           let stored,
           let modeIdentity,
           let restored = stored.restoredMonth(
                revision: revision,
                localFileID: files.localFileID,
                budgetID: budgetID,
                groupID: metadata.groupID,
                preferredCalendarMonth: preferredCalendarMonth,
                modeIdentity: modeIdentity
           ) {
            let context = BudgetLaunchSnapshotContext(
                localFileID: files.localFileID,
                budgetID: budgetID,
                groupID: metadata.groupID,
                preferredCalendarMonth: preferredCalendarMonth,
                displayedMonth: restored.selectedMonth
            )
            store.launchSnapshotContext = context
            store.launchSnapshotWrittenRevision = revision
            // Publish the complete projection before ancillary caches. Observation
            // callbacks can request the month synchronously from either later write.
            store.loadedBudgetMonthsByBudget[budgetID] = restored
            store.monthsByBudget[budgetID] = restored.availableMonths
            store.currencyByBudget[budgetID] = restored.currency
            LaunchSignpost.event(LaunchStage.launchSnapshotHit)
            return
        }

        LaunchSignpost.event(LaunchStage.launchSnapshotMiss)
        await seedBudgetFromLiveProjection(
            database: database,
            files: files,
            metadata: metadata,
            budgetID: budgetID,
            preferredCalendarMonth: preferredCalendarMonth,
            expectedRevision: currentRevision ?? revision
        )
    }

    private func seedBudgetFromLiveProjection(
        database: BudgetDatabase,
        files: BudgetLaunchSnapshotFiles,
        metadata: LocalFirstBudgetMetadata,
        budgetID: String,
        preferredCalendarMonth: String,
        expectedRevision: UInt64?
    ) async {
        let loaded = try? await LaunchSignpost.measure(LaunchStage.launchLiveProjectionFallback) {
            try await store.budget.currentBudgetMonth(
                budgetID: budgetID,
                preferredMonth: preferredCalendarMonth
            )
        }
        guard let loaded, !Task.isCancelled,
              store.database === database, store.openedBudgetID == budgetID else { return }
        store.launchSnapshotContext = BudgetLaunchSnapshotContext(
            localFileID: files.localFileID,
            budgetID: budgetID,
            groupID: metadata.groupID,
            preferredCalendarMonth: preferredCalendarMonth,
            displayedMonth: loaded.selectedMonth
        )
        if let expectedRevision {
            await persistBudgetLaunchSnapshot(loaded, revision: expectedRevision)
        }
    }

    /// Reuses a projection a normal read already produced. The compare-and-write
    /// means a mutation that advances the persistent generation while this read
    /// is running wins; the older projection is discarded instead of installed.
    func persistBudgetLaunchSnapshotIfCanonical(
        _ loaded: LoadedBudgetMonth,
        revision: UInt64
    ) async {
        guard let context = store.launchSnapshotContext,
              context.budgetID == store.openedBudgetID,
              context.displayedMonth == loaded.selectedMonth,
              context.preferredCalendarMonth == YearMonth(date: Date()).rawValue else {
            return
        }
        await persistBudgetLaunchSnapshot(loaded, revision: revision)
    }

    private func persistBudgetLaunchSnapshot(_ loaded: LoadedBudgetMonth, revision: UInt64) async {
        guard store.launchSnapshotWrittenRevision != revision else { return }
        guard let files = store.launchSnapshotFiles,
              let context = store.launchSnapshotContext,
              let snapshot = BudgetLaunchSnapshot(
                revision: revision,
                localFileID: context.localFileID,
                budgetID: context.budgetID,
                groupID: context.groupID,
                preferredCalendarMonth: context.preferredCalendarMonth,
                loaded: loaded
              ) else {
            return
        }
        let session = store.budgetSessionGeneration
        let didWrite = try? await LaunchSignpost.measure(LaunchStage.launchSnapshotWrite) {
            try await files.storeSnapshot(snapshot, ifRevisionIs: revision)
        }
        // The write is compare-and-write on the file's own revision, so a stale
        // result is harmless on disk; only the in-memory marker needs the session
        // to be the one that started the write.
        if didWrite == true, session == store.budgetSessionGeneration {
            store.launchSnapshotWrittenRevision = revision
        }
    }

    /// Post-presentation launch enrichment: the account, payee, and diagnostic
    /// state that used to be read before the first Budget frame.
    ///
    /// The Budget is already on screen when this runs, so it may be cancelled or
    /// fail without changing what the user sees: failures leave the presented
    /// snapshot and the caches' previous values in place.
    func warmLaunchCaches(budgetID: String) async {
        guard let database = store.database, owns(database, budgetID: budgetID) else { return }
        await LaunchSignpost.measure(LaunchStage.launchWarmup) {
            await LaunchSignpost.measure(LaunchStage.accountWarmup) {
                try? await store.reloadAccountCaches(database: database, budgetID: budgetID, bestEffort: true)
            }
            guard owns(database, budgetID: budgetID) else { return }
            await LaunchSignpost.measure(LaunchStage.payeeWarmup) {
                let snapshot = try? await PayeeManagementSQL.fetchPayeeManagementSnapshot(in: database)
                guard owns(database, budgetID: budgetID), let snapshot else { return }
                store.payeesByBudget[budgetID] = snapshot
                    .settingCanUndo(store.lastPayeeUndoMessagesByBudget[budgetID]?.isEmpty == false)
            }
            guard owns(database, budgetID: budgetID) else { return }
            await LaunchSignpost.measure(LaunchStage.diagnosticWarmup) {
                let snapshot = try? await ActionLogStorageSQL.actionLogDiagnosticSnapshot(in: database)
                guard owns(database, budgetID: budgetID), let snapshot else { return }
                store.actionLogDiagnosticSnapshot = snapshot
            }
            guard owns(database, budgetID: budgetID) else { return }
            await LaunchSignpost.measure(LaunchStage.syncStatusRestore) {
                // Sequenced like `recordSyncStatus`: a pending count read before a
                // newer status landed must not overwrite it.
                store.syncStatusSequence &+= 1
                let sequence = store.syncStatusSequence
                let checkpoint = try? await database.localSyncCheckpoint()
                let pending = try? await database.pendingLocalSyncMessageCount()
                #if DEBUG
                await store.testSeams?.readPublicationHook?(.launchWarmupSyncStatus)
                #endif
                guard owns(database, budgetID: budgetID) else { return }
                if let checkpoint {
                    store.syncStatus?.lastSyncedAt = checkpoint.lastSyncedAt
                    store.syncStatus?.lastAppliedMessageCount = checkpoint.lastAppliedMessageCount
                    store.syncStatus?.lastUploadedMessageCount = checkpoint.lastUploadedMessageCount
                }
                if let pending, sequence > store.appliedPendingCountSequence {
                    store.appliedPendingCountSequence = sequence
                    store.syncStatus?.pendingLocalMessageCount = pending
                }
            }
        }
    }

    /// The warmed database must still be the open budget when the read finishes,
    /// otherwise a budget switch could publish one budget's rows as another's.
    private func owns(_ database: BudgetDatabase, budgetID: String) -> Bool {
        !Task.isCancelled && store.database === database && store.openedBudgetID == budgetID
    }
}
