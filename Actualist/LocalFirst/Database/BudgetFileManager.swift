import Foundation
import CryptoKit
import ZIPFoundation

struct LocalFirstResourceLimits: Equatable, Sendable {
    let maximumCompressedBudgetBytes: UInt64
    let maximumExpandedBudgetBytes: UInt64
    let maximumArchiveEntryBytes: UInt64
    let maximumArchiveEntryCount: Int
    let maximumArchivePathDepth: Int
    let minimumFreeDiskReserveBytes: Int64
    let maximumSyncResponseBytes: Int

    /// Normal Actual budgets are far smaller than these ceilings. The 256 MiB archive and
    /// 1 GiB expansion allowances leave room for unusually long histories; the lower per-entry,
    /// count, and depth limits bound decompression work and path abuse. Imports retain 256 MiB
    /// for iOS recovery, while a 32 MiB sync response is ample for incremental CRDT traffic.
    static let standard = LocalFirstResourceLimits(
        maximumCompressedBudgetBytes: 256 * 1_024 * 1_024,
        maximumExpandedBudgetBytes: 1_024 * 1_024 * 1_024,
        maximumArchiveEntryBytes: 768 * 1_024 * 1_024,
        maximumArchiveEntryCount: 10_000,
        maximumArchivePathDepth: 16,
        minimumFreeDiskReserveBytes: 256 * 1_024 * 1_024,
        maximumSyncResponseBytes: 32 * 1_024 * 1_024
    )
}

enum BudgetReimportCheckpoint: Equatable {
    case afterDownload
    case beforeDecrypt
    case beforeExtract
    case beforeSwap
}

struct BudgetReimportWorkspace {
    let directoryURL: URL
    let archiveURL: URL
    let databaseURL: URL
    let metadataURL: URL
}

struct BudgetFileManager {
    private static let sqliteSidecarSuffixes = ["-wal", "-shm", "-journal"]

    let applicationSupportURL: URL
    private let fileManager: FileManager
    private let resourceLimits: LocalFirstResourceLimits
    private let reimportFailureInjector: ((BudgetReimportCheckpoint) throws -> Void)?

    init(
        applicationSupportURL: URL? = nil,
        fileManager: FileManager = .default,
        resourceLimits: LocalFirstResourceLimits = .standard,
        reimportFailureInjector: ((BudgetReimportCheckpoint) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.resourceLimits = resourceLimits
        self.reimportFailureInjector = reimportFailureInjector
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
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        let backup = try reimportBackupDirectory(fileID: fileID)
        if fileManager.fileExists(atPath: backup.path) {
            try fileManager.removeItem(at: backup)
        }
    }

    func deleteAllImportedBudgets() throws {
        let budgetsDirectory = try budgetRootURL()
        guard fileManager.fileExists(atPath: budgetsDirectory.path) else {
            return
        }
        try fileManager.removeItem(at: budgetsDirectory)
    }

    func prepareDownloadStaging(fileID: String) throws -> URL {
        try migrateLegacyBudgetDirectoryIfNeeded(fileID: fileID)
        let directory = try budgetDirectory(fileID: fileID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try hardenBudgetArtifact(at: directory, excludeFromBackup: true)

        let stagingURL = try containedURL(directory.appending(path: "download.staging"))
        if fileManager.fileExists(atPath: stagingURL.path) {
            try fileManager.removeItem(at: stagingURL)
        }
        guard fileManager.createFile(atPath: stagingURL.path, contents: nil) else {
            throw LocalFirstError.invalidDownloadedBudget
        }
        do {
            try hardenBudgetArtifact(at: stagingURL, excludeFromBackup: true)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
        return stagingURL
    }

    func cleanupDownloadStaging(at stagingURL: URL) {
        guard let stagingURL = try? containedURL(stagingURL),
              fileManager.fileExists(atPath: stagingURL.path) else {
            return
        }
        try? fileManager.removeItem(at: stagingURL)
    }

    func prepareReimportWorkspace(fileID: String) throws -> BudgetReimportWorkspace {
        try migrateLegacyBudgetDirectoryIfNeeded(fileID: fileID)
        guard importedDatabaseExists(fileID: fileID) else {
            throw LocalFirstError.missingImportedDatabase
        }

        let liveDirectory = try budgetDirectory(fileID: fileID)
        let directory = try containedURL(
            liveDirectory
                .deletingLastPathComponent()
                .appending(
                    path: "\(liveDirectory.lastPathComponent).reimport-\(UUID().uuidString)",
                    directoryHint: .isDirectory
                )
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try hardenBudgetArtifact(at: directory, excludeFromBackup: true)

            let archiveURL = try containedURL(directory.appending(path: "download.staging"))
            guard fileManager.createFile(atPath: archiveURL.path, contents: nil) else {
                throw LocalFirstError.invalidDownloadedBudget
            }
            try hardenBudgetArtifact(at: archiveURL, excludeFromBackup: true)
            return BudgetReimportWorkspace(
                directoryURL: directory,
                archiveURL: archiveURL,
                databaseURL: try containedURL(directory.appending(path: "db.sqlite")),
                metadataURL: try containedURL(directory.appending(path: "metadata.json"))
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func cleanupReimportWorkspace(_ workspace: BudgetReimportWorkspace) {
        guard let directory = try? containedURL(workspace.directoryURL),
              fileManager.fileExists(atPath: directory.path) else {
            return
        }
        try? fileManager.removeItem(at: directory)
    }

    func reimportCheckpoint(_ checkpoint: BudgetReimportCheckpoint) throws {
        try reimportFailureInjector?(checkpoint)
    }

    func hardenCachedBudget(fileID: String) throws {
        try migrateLegacyBudgetDirectoryIfNeeded(fileID: fileID)
        let artifacts = try cachedBudgetArtifacts(fileID: fileID)
        for artifact in artifacts {
            try hardenBudgetArtifact(at: artifact, excludeFromBackup: true)
        }
    }

    func cachedBudgetArtifacts(fileID: String) throws -> [URL] {
        let directory = try budgetDirectory(fileID: fileID)
        let database = try databaseURL(fileID: fileID)
        let metadata = try metadataURL(fileID: fileID)
        guard fileManager.fileExists(atPath: directory.path),
              fileManager.fileExists(atPath: database.path),
              fileManager.fileExists(atPath: metadata.path) else {
            throw LocalFirstError.missingImportedDatabase
        }

        var artifacts = [directory, database, metadata]
        artifacts.append(contentsOf: try Self.sqliteSidecarSuffixes.compactMap { suffix in
            let sidecar = try containedURL(
                directory.appending(path: database.lastPathComponent + suffix)
            )
            return fileManager.fileExists(atPath: sidecar.path) ? sidecar : nil
        })
        return artifacts
    }

    func validateStagedDownload(at stagingURL: URL) throws {
        let stagingURL = try containedURL(stagingURL)
        let size = try fileSize(at: stagingURL)
        guard size <= resourceLimits.maximumCompressedBudgetBytes else {
            throw LocalFirstError.remoteDataLimitExceeded
        }
        try hardenBudgetArtifact(at: stagingURL, excludeFromBackup: true)
    }

    func replaceStagedDownload(at stagingURL: URL, with data: Data) throws {
        guard UInt64(data.count) <= resourceLimits.maximumCompressedBudgetBytes else {
            throw LocalFirstError.remoteDataLimitExceeded
        }
        let stagingURL = try containedURL(stagingURL)
        try data.write(to: stagingURL, options: .atomic)
        try validateStagedDownload(at: stagingURL)
    }

    func importBudgetZip(
        at stagedArchiveURL: URL,
        remoteFile: ActualSyncRemoteFile,
        metadata: LocalFirstBudgetMetadata
    ) throws -> URL {
        try migrateLegacyBudgetDirectoryIfNeeded(fileID: remoteFile.fileID)
        let directory = try budgetDirectory(fileID: remoteFile.fileID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try hardenBudgetArtifact(at: directory, excludeFromBackup: true)

        return try importBudgetZip(
            at: stagedArchiveURL,
            into: directory,
            databaseURL: databaseURL(fileID: remoteFile.fileID),
            metadataURL: metadataURL(fileID: remoteFile.fileID),
            metadata: metadata
        )
    }

    func importBudgetZip(
        at stagedArchiveURL: URL,
        into workspace: BudgetReimportWorkspace,
        metadata: LocalFirstBudgetMetadata
    ) throws -> URL {
        try reimportCheckpoint(.beforeExtract)
        return try importBudgetZip(
            at: stagedArchiveURL,
            into: workspace.directoryURL,
            databaseURL: workspace.databaseURL,
            metadataURL: workspace.metadataURL,
            metadata: metadata
        )
    }

    func commitReimport(
        _ workspace: BudgetReimportWorkspace,
        fileID: String
    ) throws {
        try reimportCheckpoint(.beforeSwap)
        let liveDirectory = try budgetDirectory(fileID: fileID)
        guard fileManager.fileExists(atPath: liveDirectory.path) else {
            throw LocalFirstError.missingImportedDatabase
        }
        let stagedDirectory = try containedURL(workspace.directoryURL)
        guard fileManager.fileExists(atPath: stagedDirectory.path) else {
            throw LocalFirstError.invalidDownloadedBudget
        }

        let backupDirectory = try reimportBackupDirectory(fileID: fileID)
        try fileManager.createDirectory(
            at: backupDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try hardenBudgetArtifact(
            at: backupDirectory.deletingLastPathComponent(),
            excludeFromBackup: true
        )
        if fileManager.fileExists(atPath: backupDirectory.path) {
            try fileManager.removeItem(at: backupDirectory)
        }

        try fileManager.moveItem(at: liveDirectory, to: backupDirectory)
        do {
            try fileManager.moveItem(at: stagedDirectory, to: liveDirectory)
        } catch {
            try? fileManager.moveItem(at: backupDirectory, to: liveDirectory)
            throw error
        }
    }

    func rollbackReimport(fileID: String) throws {
        let liveDirectory = try budgetDirectory(fileID: fileID)
        let backupDirectory = try reimportBackupDirectory(fileID: fileID)
        guard fileManager.fileExists(atPath: backupDirectory.path) else {
            return
        }
        if fileManager.fileExists(atPath: liveDirectory.path) {
            try fileManager.removeItem(at: liveDirectory)
        }
        try fileManager.moveItem(at: backupDirectory, to: liveDirectory)
    }

    func reimportBackupExists(fileID: String) throws -> Bool {
        fileManager.fileExists(atPath: try reimportBackupDirectory(fileID: fileID).path)
    }

    private func importBudgetZip(
        at stagedArchiveURL: URL,
        into directory: URL,
        databaseURL: URL,
        metadataURL: URL,
        metadata: LocalFirstBudgetMetadata
    ) throws -> URL {
        let directory = try containedURL(directory)
        let zipURL = try containedURL(stagedArchiveURL)
        defer { try? fileManager.removeItem(at: zipURL) }
        try validateStagedDownload(at: zipURL)

        let extractionURL = try containedURL(
            directory.appending(path: "import", directoryHint: .isDirectory)
        )
        if fileManager.fileExists(atPath: extractionURL.path) {
            try fileManager.removeItem(at: extractionURL)
        }
        try fileManager.createDirectory(at: extractionURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: extractionURL) }
        try hardenBudgetArtifact(at: extractionURL, excludeFromBackup: true)
        try extractArchive(at: zipURL, to: extractionURL)

        guard let importedDatabase = try findDatabase(in: extractionURL) else {
            throw LocalFirstError.missingImportedDatabase
        }

        let databaseURL = try containedURL(databaseURL)
        if fileManager.fileExists(atPath: databaseURL.path) {
            try fileManager.removeItem(at: databaseURL)
        }
        try fileManager.moveItem(
            at: try containedURL(importedDatabase),
            to: databaseURL
        )
        try hardenBudgetArtifact(at: databaseURL, excludeFromBackup: true)

        let metadataData = try JSONEncoder.actual.encode(metadata)
        let metadataURL = try containedURL(metadataURL)
        try metadataData.write(to: metadataURL, options: .atomic)
        try hardenBudgetArtifact(at: metadataURL, excludeFromBackup: true)
        return databaseURL
    }

    private func extractArchive(at archiveURL: URL, to extractionURL: URL) throws {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        let entries = Array(archive)
        guard entries.count <= resourceLimits.maximumArchiveEntryCount else {
            throw LocalFirstError.remoteDataLimitExceeded
        }

        var totalExpandedBytes: UInt64 = 0
        for entry in entries {
            try validateArchivePath(entry.path)
            guard entry.type != .symlink else {
                throw LocalFirstError.invalidDownloadedBudget
            }
            guard entry.uncompressedSize <= resourceLimits.maximumArchiveEntryBytes else {
                throw LocalFirstError.remoteDataLimitExceeded
            }
            let (nextTotal, overflow) = totalExpandedBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, nextTotal <= resourceLimits.maximumExpandedBudgetBytes else {
                throw LocalFirstError.remoteDataLimitExceeded
            }
            totalExpandedBytes = nextTotal
        }

        try requireAvailableDiskSpace(forExpandedBytes: totalExpandedBytes)

        var extractedBytes: UInt64 = 0
        for entry in entries {
            let destination = try containedURL(
                extractionURL.appending(path: entry.path)
            )
            let checksum = try archive.extract(entry, to: destination)
            guard checksum == entry.checksum else {
                throw LocalFirstError.invalidDownloadedBudget
            }
            if entry.type == .file {
                let actualSize = try fileSize(at: destination)
                guard actualSize == entry.uncompressedSize else {
                    throw LocalFirstError.invalidDownloadedBudget
                }
                let (nextExtracted, overflow) = extractedBytes.addingReportingOverflow(actualSize)
                guard !overflow, nextExtracted <= resourceLimits.maximumExpandedBudgetBytes else {
                    throw LocalFirstError.remoteDataLimitExceeded
                }
                extractedBytes = nextExtracted
            }
        }
    }

    private func validateArchivePath(_ path: String) throws {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !normalized.hasPrefix("/"),
              !normalized.hasPrefix("//"),
              !(normalized as NSString).isAbsolutePath,
              !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw LocalFirstError.invalidDownloadedBudget
        }
        guard components.count <= resourceLimits.maximumArchivePathDepth else {
            throw LocalFirstError.remoteDataLimitExceeded
        }
        if let first = components.first,
           first.count == 2,
           first.last == ":" {
            throw LocalFirstError.invalidDownloadedBudget
        }
    }

    private func requireAvailableDiskSpace(forExpandedBytes expandedBytes: UInt64) throws {
        guard expandedBytes <= UInt64(Int64.max) else {
            throw LocalFirstError.remoteDataLimitExceeded
        }
        // The staged archive is already reflected in available capacity. Require enough room
        // for the complete expansion while retaining a recovery reserve for the rest of iOS.
        let withReserve = Int64(expandedBytes)
            .addingReportingOverflow(resourceLimits.minimumFreeDiskReserveBytes)
        let availableBytes = try? applicationSupportURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        guard !withReserve.overflow,
              let availableBytes,
              availableBytes >= withReserve.partialValue else {
            throw LocalFirstError.insufficientStorage
        }
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw LocalFirstError.invalidDownloadedBudget
        }
        return number.uint64Value
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

    private func reimportBackupDirectory(fileID: String) throws -> URL {
        try validate(fileID: fileID)
        let backupRoot = try containedURL(
            budgetRootURL().appending(path: ".ReimportBackups", directoryHint: .isDirectory)
        )
        let backup = backupRoot.appending(
            path: SHA256.hash(data: Data(fileID.utf8)).hexString,
            directoryHint: .isDirectory
        )
        return try containedURL(backup)
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

        #if os(iOS) && !targetEnvironment(simulator)
        // Simulator resource values do not model device data protection or backup policy.
        let effectiveValues = try resourceURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        guard effectiveValues.isExcludedFromBackup == excludeFromBackup else {
            throw LocalFirstError.localBudgetHardeningFailed
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.protectionKey] as? FileProtectionType
            == .completeUntilFirstUserAuthentication else {
            throw LocalFirstError.localBudgetHardeningFailed
        }
        #endif
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
