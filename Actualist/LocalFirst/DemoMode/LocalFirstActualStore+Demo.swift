import Foundation

extension LocalFirstActualStore {
    /// Install (if missing or stale) and open the bundled demo budget.
    ///
    /// Uses the existing `BudgetFileManager` import path with deterministic
    /// metadata (no server URL, no token, no encryption context), then opens
    /// the imported database through `openImportedBudget`. Reinstalls when the
    /// on-disk fileID differs from the current `DemoBudget.fileID`, so an app
    /// update that bumps the demo version replaces a stale dataset. Never
    /// touches a sync or connection transport.
    func openDemoBudget() async throws {
        let fileID = DemoBudget.fileID
        let needsInstall = try demoBudgetNeedsInstall(fileID: fileID)
        if needsInstall {
            try fileManager.deleteImportedBudget(fileID: fileID)
            let archiveData = try DemoBudget.bundledArchiveData()
            let stagingURL = try fileManager.prepareDownloadStaging(fileID: fileID)
            defer { fileManager.cleanupDownloadStaging(at: stagingURL) }
            try fileManager.replaceStagedDownload(at: stagingURL, with: archiveData)
            let remoteFile = ActualSyncRemoteFile(
                fileID: fileID,
                groupID: DemoBudget.groupID,
                name: DemoBudget.name
            )
            _ = try fileManager.importBudgetZip(
                at: stagingURL,
                remoteFile: remoteFile,
                metadata: DemoBudget.metadata()
            )
        }
        try await openImportedBudget(fileID: fileID, metadata: DemoBudget.metadata())
    }

    /// Reinstall when the demo budget is missing or the on-disk version no
    /// longer matches the current `DemoBudget.fileID` (stale fixture from an
    /// older app build).
    private func demoBudgetNeedsInstall(fileID: String) throws -> Bool {
        guard fileManager.importedDatabaseExists(fileID: fileID) else {
            return true
        }
        guard let metadata = try fileManager.loadMetadata(fileID: fileID) else {
            return true
        }
        return metadata.cloudFileID != DemoBudget.fileID
    }
}
