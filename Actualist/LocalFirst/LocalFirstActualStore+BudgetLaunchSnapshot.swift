import Foundation

extension LocalFirstActualStore {
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
            revision = try LaunchSignpost.measureSync(LaunchStage.launchSnapshotRevisionRead) {
                try files.prepareRevision()
            }
        } catch {
            LaunchSignpost.event(LaunchStage.launchSnapshotMiss)
            await seedBudgetFromLiveProjection(
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
            let pair = try LaunchSignpost.measureSync(LaunchStage.launchSnapshotRead) {
                try files.readRevisionAndSnapshot()
            }
            guard pair.revision == revision else {
                LaunchSignpost.event(LaunchStage.launchSnapshotMiss)
                await seedBudgetFromLiveProjection(
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

        let modeIdentity = try? await database.fetchBudgetModeIdentity()
        if let revision,
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
            launchSnapshotContext = context
            launchSnapshotWrittenRevision = revision
            // Publish the complete projection before ancillary caches. Observation
            // callbacks can request the month synchronously from either later write.
            loadedBudgetMonthsByBudget[budgetID] = restored
            monthsByBudget[budgetID] = restored.availableMonths
            currencyByBudget[budgetID] = restored.currency
            LaunchSignpost.event(LaunchStage.launchSnapshotHit)
            return
        }

        LaunchSignpost.event(LaunchStage.launchSnapshotMiss)
        await seedBudgetFromLiveProjection(
            files: files,
            metadata: metadata,
            budgetID: budgetID,
            preferredCalendarMonth: preferredCalendarMonth,
            expectedRevision: revision
        )
    }

    private func seedBudgetFromLiveProjection(
        files: BudgetLaunchSnapshotFiles,
        metadata: LocalFirstBudgetMetadata,
        budgetID: String,
        preferredCalendarMonth: String,
        expectedRevision: UInt64?
    ) async {
        let loaded = try? await LaunchSignpost.measure(LaunchStage.launchLiveProjectionFallback) {
            try await currentBudgetMonth(
                budgetID: budgetID,
                preferredMonth: preferredCalendarMonth
            )
        }
        guard let loaded else { return }
        launchSnapshotContext = BudgetLaunchSnapshotContext(
            localFileID: files.localFileID,
            budgetID: budgetID,
            groupID: metadata.groupID,
            preferredCalendarMonth: preferredCalendarMonth,
            displayedMonth: loaded.selectedMonth
        )
        if let expectedRevision {
            persistBudgetLaunchSnapshot(loaded, revision: expectedRevision)
        }
    }

    /// Reuses a projection a normal read already produced. The compare-and-write
    /// means a mutation that advances the persistent generation while this read
    /// is running wins; the older projection is discarded instead of installed.
    func persistBudgetLaunchSnapshotIfCanonical(
        _ loaded: LoadedBudgetMonth,
        revision: UInt64
    ) {
        guard let context = launchSnapshotContext,
              context.budgetID == openedBudgetID,
              context.displayedMonth == loaded.selectedMonth,
              context.preferredCalendarMonth == YearMonth(date: Date()).rawValue else {
            return
        }
        persistBudgetLaunchSnapshot(loaded, revision: revision)
    }

    private func persistBudgetLaunchSnapshot(_ loaded: LoadedBudgetMonth, revision: UInt64) {
        guard launchSnapshotWrittenRevision != revision else { return }
        guard let files = launchSnapshotFiles,
              let context = launchSnapshotContext,
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
        let didWrite = try? LaunchSignpost.measureSync(LaunchStage.launchSnapshotWrite) {
            try files.writeSnapshot(snapshot, ifRevisionIs: revision)
        }
        if didWrite == true {
            launchSnapshotWrittenRevision = revision
        }
    }
}
