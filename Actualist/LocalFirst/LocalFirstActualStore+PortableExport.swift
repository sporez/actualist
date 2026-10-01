import Foundation

extension LocalFirstActualStore {
    /// Exports the currently open budget as a portable ZIP through the
    /// existing `PortableBudgetArchive` export: a consistent snapshot of the
    /// open database (never a live `db.sqlite` copy) plus allowlisted
    /// metadata, written to a fresh temporary file the caller shares. Nothing
    /// is uploaded, the server is never contacted, and the open budget's
    /// local files are unchanged.
    ///
    /// Refuses when `budgetID` is not the open budget. If the budget switches
    /// while the snapshot is being written, the finished archive is deleted
    /// and the export reports cancellation, mirroring the CSV export's
    /// stale-result handling.
    func exportPortableBudgetArchive(budgetID: String) async throws -> URL {
        let database = try requireDatabase(for: budgetID)
        // The open budget's local files are keyed by its cloud file ID, which
        // differs from `budgetID` (the group-based open-budget identity)
        // whenever the budget belongs to a group. The sync session retains
        // that file ID for the open budget; a stale or closed session leaves
        // it unset, and the post-export open-budget guard discards the result.
        guard let fileID = await syncClient.configuration?.fileID else {
            throw LocalFirstError.budgetNotOpened
        }
        // The local metadata is the source of truth for the open budget's
        // name; the cached server list only covers a metadata read failure.
        let metadata = try? fileManager.loadMetadata(fileID: fileID)
        let budgetName = metadata?.budgetName
            ?? cachedBudgets.first(where: { $0.syncID == budgetID })?.name
            ?? ""
        let archiveURL = FileManager.default.temporaryDirectory
            .appending(path: "budget-export-\(UUID().uuidString).zip")
        _ = try await PortableBudgetArchive().export(
            database: database,
            budgetName: budgetName,
            sourceIdentity: budgetID,
            to: archiveURL
        )
        guard self.database === database, openedBudgetID == budgetID else {
            try? FileManager.default.removeItem(at: archiveURL)
            throw CancellationError()
        }
        return archiveURL
    }
}
