import Foundation

/// The bundled demo budget on the store: installing it and opening it as
/// the session's budget. The store owns it.
@MainActor
final class DemoBudgetWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    /// Install (if missing or stale) and open the bundled demo budget.
    ///
    /// Uses the existing `BudgetFileManager` import path with deterministic
    /// metadata (no server URL, no token, no encryption context), then opens
    /// the imported database through `openImportedBudget`. Reinstalls when the
    /// on-disk fileID differs from the current `DemoBudget.fileID`, so an app
    /// update that bumps the demo version replaces a stale dataset. Never
    /// touches a sync or connection transport.
    func openDemoBudget(tracking: Bool = false) async throws {
        let fileID = DemoBudget.fileID
        let expectedGeneration = store.budgetSessionGeneration
        let needsInstall = try demoBudgetNeedsInstall(fileID: fileID)
        if needsInstall || tracking {
            try store.fileManager.deleteImportedBudget(fileID: fileID)
            let archiveData = try DemoBudget.bundledArchiveData(tracking: tracking)
            let stagingURL = try store.fileManager.prepareDownloadStaging(fileID: fileID)
            defer { store.fileManager.cleanupDownloadStaging(at: stagingURL) }
            try store.fileManager.replaceStagedDownload(at: stagingURL, with: archiveData)
            let remoteFile = ActualSyncRemoteFile(
                fileID: fileID,
                groupID: DemoBudget.groupID,
                name: DemoBudget.name
            )
            _ = try await store.fileManager.importBudgetZip(
                at: stagingURL,
                remoteFile: remoteFile,
                metadata: DemoBudget.metadata()
            )
        }
        try await store.openImportedBudget(
            fileID: fileID, metadata: DemoBudget.metadata(), expectedGeneration: expectedGeneration
        )
    }

    /// Reinstall when the demo budget is missing or the on-disk version no
    /// longer matches the current `DemoBudget.fileID` (stale fixture from an
    /// older app build).
    private func demoBudgetNeedsInstall(fileID: String) throws -> Bool {
        guard store.fileManager.importedDatabaseExists(fileID: fileID) else {
            return true
        }
        guard let metadata = try store.fileManager.loadMetadata(fileID: fileID) else {
            return true
        }
        return metadata.cloudFileID != DemoBudget.fileID
    }
}
