import Foundation

extension BudgetFileManager {
    /// Installs an already validated portable `db.sqlite` + `metadata.json`
    /// pair into a new budget directory for a caller-supplied file ID.
    ///
    /// The caller owns archive validation (`PortableBudgetArchive`) and mints
    /// the file ID exactly once. This entry never accepts a zip and never
    /// runs the download installer (`importBudgetZip`) or the reimport swap
    /// (`reimportBudget`): only the two validated files are copied into place,
    /// then the existing `hardenCachedBudget` hardening runs. A directory
    /// that already exists for the file ID is refused untouched — an import
    /// attempt never deletes an existing budget's files.
    func installValidatedPortableBudget(
        databaseAt validatedDatabaseURL: URL,
        metadataAt validatedMetadataURL: URL,
        fileID: String
    ) throws {
        let directory = try budgetDirectory(fileID: fileID)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw NewBudgetError.budgetDirectoryAlreadyExists
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(
                at: validatedDatabaseURL,
                to: try databaseURL(fileID: fileID)
            )
            try FileManager.default.copyItem(
                at: validatedMetadataURL,
                to: try metadataURL(fileID: fileID)
            )
            try hardenCachedBudget(fileID: fileID)
        } catch {
            // A half-installed directory is never a budget; only a directory
            // this call created is removed, never a pre-existing one.
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
