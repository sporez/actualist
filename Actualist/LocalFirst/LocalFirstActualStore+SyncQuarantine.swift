import Foundation

extension LocalFirstActualStore {
    /// Records one diagnostic for remote values that were stored but not applied
    /// because they could not be read. Counts and timestamps only: values and
    /// keys never reach the diagnostic.
    func recordQuarantinedSyncValues(_ timestamps: [String]) {
        guard let earliest = timestamps.min(), let latest = timestamps.max() else { return }
        recordSyncDebugEvent(
            outcome: .failed,
            pendingBefore: 0,
            pendingAfter: 0,
            message: SafeSyncDiagnostic.quarantineMessage(
                count: timestamps.count,
                earliest: earliest,
                latest: latest
            ),
            endpoint: lastSyncEndpoint
        )
    }
}
