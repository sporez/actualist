import Foundation

extension LocalFirstActualStore {
    /// Post-presentation launch enrichment: the account, payee, and diagnostic
    /// state that used to be read before the first Budget frame.
    ///
    /// The Budget is already on screen when this runs, so it may be cancelled or
    /// fail without changing what the user sees: failures leave the presented
    /// snapshot and the caches' previous values in place.
    func warmLaunchCaches(budgetID: String) async {
        guard let database, owns(database, budgetID: budgetID) else { return }
        await LaunchSignpost.measure(LaunchStage.launchWarmup) {
            await LaunchSignpost.measure(LaunchStage.accountWarmup) {
                try? await reloadAccountCaches(database: database, budgetID: budgetID)
            }
            guard owns(database, budgetID: budgetID) else { return }
            await LaunchSignpost.measure(LaunchStage.payeeWarmup) {
                payeesByBudget[budgetID] = try? await database.fetchPayeeManagementSnapshot()
                    .settingCanUndo(lastPayeeUndoMessagesByBudget[budgetID]?.isEmpty == false)
            }
            guard owns(database, budgetID: budgetID) else { return }
            await LaunchSignpost.measure(LaunchStage.diagnosticWarmup) {
                await refreshActionLogDiagnosticSnapshot(database: database)
            }
            guard owns(database, budgetID: budgetID) else { return }
            await LaunchSignpost.measure(LaunchStage.syncStatusRestore) {
                let checkpoint = try? await database.localSyncCheckpoint()
                let pending = (try? await database.pendingLocalSyncMessageCount()) ?? 0
                guard owns(database, budgetID: budgetID) else { return }
                syncStatus?.lastSyncedAt = checkpoint?.lastSyncedAt
                syncStatus?.lastAppliedMessageCount = checkpoint?.lastAppliedMessageCount ?? 0
                syncStatus?.lastUploadedMessageCount = checkpoint?.lastUploadedMessageCount ?? 0
                syncStatus?.pendingLocalMessageCount = pending
            }
        }
    }

    /// The warmed database must still be the open budget when the read finishes,
    /// otherwise a budget switch could publish one budget's rows as another's.
    private func owns(_ database: BudgetDatabase, budgetID: String) -> Bool {
        !Task.isCancelled && self.database === database && openedBudgetID == budgetID
    }
}
