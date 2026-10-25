import Foundation

/// What one sync round applied to SQLite before it ended, so a round that
/// throws after applying remote messages can still refresh the screens and
/// report the new transactions. `SyncClient` records every apply into it.
actor PartialSyncApplyRecorder {
    private var total = BudgetDatabase.RemoteSyncApplyResult.empty

    func record(_ applied: BudgetDatabase.RemoteSyncApplyResult) {
        total = total.merging(applied)
    }

    var applied: BudgetDatabase.RemoteSyncApplyResult { total }
}

enum PartialSyncApply {
    /// Called from a failed round's catch, before the error is rethrown. When
    /// nothing was applied it does nothing. Otherwise it credits the new
    /// transaction IDs to the active background run and runs `reload`; a
    /// failing or cancelled reload never replaces the round's own error.
    /// `lane` is the session's lane captured by the caller: an invalidated
    /// lane drops the IDs, and `reload` re-checks the session itself.
    @MainActor
    static func settleAfterFailure(
        _ recorder: PartialSyncApplyRecorder,
        lane: ServerSyncLane,
        reload: () async throws -> Void
    ) async {
        let applied = await recorder.applied
        guard applied.appliedMessageCount > 0 else { return }
        lane.noteInserted(applied.insertedTransactionIDsByAccount)
        try? await reload()
    }
}

/// A background refresh whose pull applied remote transactions and then
/// failed. Carries the pulled transactions so the run can still report them,
/// and the original error so the run still ends as failed.
struct BackgroundRefreshPartialFailure: Error {
    let underlying: any Error
    let results: [BackgroundAccountRefreshResult]
}
