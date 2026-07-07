import Foundation
import ZIPFoundation

struct BudgetFileManager {
    let applicationSupportURL: URL
    private let fileManager: FileManager

    init(
        applicationSupportURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.applicationSupportURL = applicationSupportURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appending(path: "Actualist", directoryHint: .isDirectory)
    }

    func budgetDirectory(fileID: String) -> URL {
        applicationSupportURL
            .appending(path: "Budgets", directoryHint: .isDirectory)
            .appending(path: sanitized(fileID), directoryHint: .isDirectory)
    }

    func databaseURL(fileID: String) -> URL {
        budgetDirectory(fileID: fileID).appending(path: "db.sqlite")
    }

    func metadataURL(fileID: String) -> URL {
        budgetDirectory(fileID: fileID).appending(path: "metadata.json")
    }

    func loadMetadata(fileID: String) throws -> LocalFirstBudgetMetadata? {
        let url = metadataURL(fileID: fileID)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.actual.decode(LocalFirstBudgetMetadata.self, from: data)
    }

    func importedDatabaseExists(fileID: String) -> Bool {
        fileManager.fileExists(atPath: databaseURL(fileID: fileID).path)
    }

    func importedBudgetFileIDs() throws -> [String] {
        let budgetsDirectory = applicationSupportURL.appending(path: "Budgets", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: budgetsDirectory.path) else {
            return []
        }
        let urls = try fileManager.contentsOfDirectory(
            at: budgetsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try urls.compactMap { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                return nil
            }
            return url.lastPathComponent
        }
    }

    /// Removes the imported budget directory (database + metadata) so the next open
    /// re-downloads a fresh copy from the server. A no-op when nothing is imported.
    func deleteImportedBudget(fileID: String) throws {
        let directory = budgetDirectory(fileID: fileID)
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        try fileManager.removeItem(at: directory)
    }

    func deleteAllImportedBudgets() throws {
        let budgetsDirectory = applicationSupportURL.appending(path: "Budgets", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: budgetsDirectory.path) else {
            return
        }
        try fileManager.removeItem(at: budgetsDirectory)
    }

    func importBudgetZip(
        _ data: Data,
        remoteFile: ActualSyncRemoteFile,
        metadata: LocalFirstBudgetMetadata
    ) throws -> URL {
        let directory = budgetDirectory(fileID: remoteFile.fileID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try hardenBudgetArtifact(at: directory, excludeFromBackup: true)

        let zipURL = directory.appending(path: "download.zip")
        try data.write(to: zipURL, options: .atomic)
        try hardenBudgetArtifact(at: zipURL, excludeFromBackup: true)

        let extractionURL = directory.appending(path: "import", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: extractionURL.path) {
            try fileManager.removeItem(at: extractionURL)
        }
        try fileManager.createDirectory(at: extractionURL, withIntermediateDirectories: true)
        try hardenBudgetArtifact(at: extractionURL, excludeFromBackup: true)
        try fileManager.unzipItem(at: zipURL, to: extractionURL)

        guard let importedDatabase = try findDatabase(in: extractionURL) else {
            throw LocalFirstError.missingImportedDatabase
        }

        let databaseURL = databaseURL(fileID: remoteFile.fileID)
        if fileManager.fileExists(atPath: databaseURL.path) {
            try fileManager.removeItem(at: databaseURL)
        }
        try fileManager.moveItem(at: importedDatabase, to: databaseURL)
        try hardenBudgetArtifact(at: databaseURL, excludeFromBackup: true)

        let metadataData = try JSONEncoder.actual.encode(metadata)
        try metadataData.write(to: metadataURL(fileID: remoteFile.fileID), options: .atomic)
        try hardenBudgetArtifact(at: metadataURL(fileID: remoteFile.fileID), excludeFromBackup: true)
        try? fileManager.removeItem(at: zipURL)
        try? fileManager.removeItem(at: extractionURL)
        return databaseURL
    }

    private func findDatabase(in directory: URL) throws -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            guard url.lastPathComponent == "db.sqlite" || url.pathExtension == "sqlite" else {
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                return url
            }
        }
        return nil
    }

    private func sanitized(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private func hardenBudgetArtifact(at url: URL, excludeFromBackup: Bool) throws {
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excludeFromBackup
        try resourceURL.setResourceValues(values)
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}
