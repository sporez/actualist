import Foundation
import CryptoKit
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

    func budgetDirectory(fileID: String) throws -> URL {
        try validate(fileID: fileID)
        let directory = try budgetRootURL()
            .appending(path: SHA256.hash(data: Data(fileID.utf8)).hexString, directoryHint: .isDirectory)
        return try containedURL(directory)
    }

    func databaseURL(fileID: String) throws -> URL {
        try containedURL(
            budgetDirectory(fileID: fileID).appending(path: "db.sqlite")
        )
    }

    func metadataURL(fileID: String) throws -> URL {
        try containedURL(
            budgetDirectory(fileID: fileID).appending(path: "metadata.json")
        )
    }

    func loadMetadata(fileID: String) throws -> LocalFirstBudgetMetadata? {
        try migrateLegacyBudgetDirectoryIfNeeded(fileID: fileID)
        let url = try metadataURL(fileID: fileID)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.actual.decode(LocalFirstBudgetMetadata.self, from: data)
    }

    func importedDatabaseExists(fileID: String) -> Bool {
        guard (try? migrateLegacyBudgetDirectoryIfNeeded(fileID: fileID)) != nil,
              let url = try? databaseURL(fileID: fileID) else {
            return false
        }
        return fileManager.fileExists(atPath: url.path)
    }

    func importedBudgetFileIDs() throws -> [String] {
        let budgetsDirectory = try budgetRootURL()
        guard fileManager.fileExists(atPath: budgetsDirectory.path) else {
            return []
        }
        let urls = try fileManager.contentsOfDirectory(
            at: budgetsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try urls.compactMap { candidate in
            let url = try containedURL(candidate)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                return nil
            }
            let metadataURL = try containedURL(url.appending(path: "metadata.json"))
            guard fileManager.fileExists(atPath: metadataURL.path) else {
                return nil
            }
            let data = try Data(contentsOf: metadataURL)
            return try JSONDecoder.actual.decode(LocalFirstBudgetMetadata.self, from: data).cloudFileID
        }
    }

    /// Removes the imported budget directory (database + metadata) so the next open
    /// re-downloads a fresh copy from the server. A no-op when nothing is imported.
    func deleteImportedBudget(fileID: String) throws {
        try migrateLegacyBudgetDirectoryIfNeeded(fileID: fileID)
        let directory = try budgetDirectory(fileID: fileID)
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        try fileManager.removeItem(at: directory)
    }

    func deleteAllImportedBudgets() throws {
        let budgetsDirectory = try budgetRootURL()
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
        try migrateLegacyBudgetDirectoryIfNeeded(fileID: remoteFile.fileID)
        let directory = try budgetDirectory(fileID: remoteFile.fileID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try hardenBudgetArtifact(at: directory, excludeFromBackup: true)

        let zipURL = try containedURL(directory.appending(path: "download.zip"))
        try data.write(to: zipURL, options: .atomic)
        try hardenBudgetArtifact(at: zipURL, excludeFromBackup: true)

        let extractionURL = try containedURL(
            directory.appending(path: "import", directoryHint: .isDirectory)
        )
        if fileManager.fileExists(atPath: extractionURL.path) {
            try fileManager.removeItem(at: extractionURL)
        }
        try fileManager.createDirectory(at: extractionURL, withIntermediateDirectories: true)
        try hardenBudgetArtifact(at: extractionURL, excludeFromBackup: true)
        try fileManager.unzipItem(
            at: try containedURL(zipURL),
            to: try containedURL(extractionURL)
        )

        guard let importedDatabase = try findDatabase(in: extractionURL) else {
            throw LocalFirstError.missingImportedDatabase
        }

        let databaseURL = try databaseURL(fileID: remoteFile.fileID)
        if fileManager.fileExists(atPath: databaseURL.path) {
            try fileManager.removeItem(at: databaseURL)
        }
        try fileManager.moveItem(
            at: try containedURL(importedDatabase),
            to: try containedURL(databaseURL)
        )
        try hardenBudgetArtifact(at: databaseURL, excludeFromBackup: true)

        let metadataData = try JSONEncoder.actual.encode(metadata)
        let metadataURL = try metadataURL(fileID: remoteFile.fileID)
        try metadataData.write(to: metadataURL, options: .atomic)
        try hardenBudgetArtifact(at: metadataURL, excludeFromBackup: true)
        try? fileManager.removeItem(at: containedURL(zipURL))
        try? fileManager.removeItem(at: containedURL(extractionURL))
        return databaseURL
    }

    private func findDatabase(in directory: URL) throws -> URL? {
        let directory = try containedURL(directory)
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            let url = try containedURL(url)
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

    private func validate(fileID: String) throws {
        guard !fileID.isEmpty, !fileID.contains("\0") else {
            throw LocalFirstError.invalidBudgetFileID
        }

        var decoded = fileID
        for _ in 0..<3 {
            guard let next = decoded.removingPercentEncoding, next != decoded else {
                break
            }
            decoded = next
        }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw LocalFirstError.invalidBudgetFileID
        }
    }

    private func migrateLegacyBudgetDirectoryIfNeeded(fileID: String) throws {
        try validate(fileID: fileID)
        let target = try budgetDirectory(fileID: fileID)
        guard !fileManager.fileExists(atPath: target.path) else {
            return
        }
        let legacyName = fileID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let legacy = try containedURL(
            budgetRootURL().appending(path: legacyName, directoryHint: .isDirectory)
        )
        guard fileManager.fileExists(atPath: legacy.path) else {
            return
        }
        try fileManager.moveItem(at: legacy, to: target)
    }

    private func budgetRootURL() throws -> URL {
        let supportRoot = applicationSupportURL.standardizedFileURL.resolvingSymlinksInPath()
        let budgetRoot = applicationSupportURL
            .appending(path: "Budgets", directoryHint: .isDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard budgetRoot.pathComponents.starts(with: supportRoot.pathComponents),
              budgetRoot.pathComponents.count > supportRoot.pathComponents.count else {
            throw LocalFirstError.invalidBudgetFileID
        }
        return budgetRoot
    }

    private func containedURL(_ candidate: URL) throws -> URL {
        let root = try budgetRootURL()
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.pathComponents.starts(with: root.pathComponents),
              resolved.pathComponents.count > root.pathComponents.count else {
            throw LocalFirstError.invalidBudgetFileID
        }
        return resolved
    }

    private func hardenBudgetArtifact(at url: URL, excludeFromBackup: Bool) throws {
        var resourceURL = try containedURL(url)
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

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
