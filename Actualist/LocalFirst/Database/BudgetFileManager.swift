import Foundation
import CryptoKit
import os

struct LocalFirstResourceLimits: Equatable, Sendable {
    let maximumCompressedBudgetBytes: UInt64
    let maximumExpandedBudgetBytes: UInt64
    let maximumArchiveEntryBytes: UInt64
    let maximumArchiveEntryCount: Int
    let maximumArchivePathDepth: Int
    let minimumFreeDiskReserveBytes: Int64
    let maximumSyncResponseBytes: Int

    // Generous size ceilings still bound decompression work and path abuse.
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
    private static let logger = Logger(subsystem: "com.sporez.actualist", category: "BudgetFiles")

    let applicationSupportURL: URL
    private let fileManager: FileManager
    private let resourceLimits: LocalFirstResourceLimits
    private let reimportFailureInjector: ((BudgetReimportCheckpoint) throws -> Void)?
    private let launchSnapshotAccess: BudgetLaunchSnapshotFileAccess

    init(
        applicationSupportURL: URL? = nil,
        fileManager: FileManager = .default,
        resourceLimits: LocalFirstResourceLimits = .standard,
        reimportFailureInjector: ((BudgetReimportCheckpoint) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.resourceLimits = resourceLimits
        self.reimportFailureInjector = reimportFailureInjector
        launchSnapshotAccess = BudgetLaunchSnapshotFileAccess(fileManager: fileManager)
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

    func launchSnapshotFiles(fileID: String) throws -> BudgetLaunchSnapshotFiles {
        let directory = try budgetDirectory(fileID: fileID)
        return BudgetLaunchSnapshotFiles(
            localFileID: fileID,
            revisionURL: try containedURL(directory.appending(path: "launch-revision.json")),
            snapshotURL: try containedURL(directory.appending(path: "launch-snapshot.json")),
            access: launchSnapshotAccess
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

    func cachedBudgetDirectoryExists(fileID: String) throws -> Bool {
        try migrateLegacyBudgetDirectoryIfNeeded(fileID: fileID)
        return fileManager.fileExists(atPath: try budgetDirectory(fileID: fileID).path)
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

        let stagingURL = try containedURL(
            directory.appending(path: "download.\(UUID().uuidString.lowercased()).staging")
        )
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

    /// Removes staging files a crashed download left behind. Downloads only run
    /// while no imported database exists, so callers sweep from the cached-open
    /// path, where no download of this file is in flight.
    func sweepStaleDownloadStaging(fileID: String) {
        guard let directory = try? budgetDirectory(fileID: fileID),
              let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names where name.hasPrefix("download.") && name.hasSuffix(".staging") {
            if let url = try? containedURL(directory.appending(path: name)) {
                try? fileManager.removeItem(at: url)
            }
        }
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
        let launchFiles = try launchSnapshotFiles(fileID: fileID)
        for sidecar in [launchFiles.revisionURL, launchFiles.snapshotURL]
        where fileManager.fileExists(atPath: sidecar.path) {
            artifacts.append(sidecar)
        }
        return artifacts
    }

    func validateStagedDownload(at stagingURL: URL) throws {
        let stagingURL = try containedURL(stagingURL)
        let size: UInt64
        do {
            size = try UntrustedZipExtractor.fileSize(at: stagingURL, fileManager: fileManager)
        } catch {
            throw LocalFirstError.invalidDownloadedBudget
        }
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
        // A backup with no live directory is the only remaining copy of the
        // budget: restore it before anything can replace or delete it.
        try restoreBackupIfLiveMissing(fileID: fileID)
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
        // The live directory exists here, so an older backup is a superseded copy.
        if fileManager.fileExists(atPath: backupDirectory.path) {
            try fileManager.removeItem(at: backupDirectory)
        }

        try fileManager.moveItem(at: liveDirectory, to: backupDirectory)
        do {
            try fileManager.moveItem(at: stagedDirectory, to: liveDirectory)
        } catch {
            do {
                try fileManager.moveItem(at: backupDirectory, to: liveDirectory)
            } catch {
                // The backup stays where it is; the next open restores it.
                Self.logger.error("Reimport swap failed and the backup could not be restored")
                throw LocalFirstError.reimportRollbackFailed
            }
            throw error
        }
    }

    func rollbackReimport(fileID: String) throws {
        let liveDirectory = try budgetDirectory(fileID: fileID)
        let backupDirectory = try reimportBackupDirectory(fileID: fileID)
        guard fileManager.fileExists(atPath: backupDirectory.path) else {
            return
        }
        do {
            if fileManager.fileExists(atPath: liveDirectory.path) {
                try fileManager.removeItem(at: liveDirectory)
            }
            try fileManager.moveItem(at: backupDirectory, to: liveDirectory)
        } catch {
            // The backup is untouched by a failed move; the next open restores it.
            Self.logger.error("Reimport rollback failed and the backup was kept")
            throw LocalFirstError.reimportRollbackFailed
        }
    }

    /// Removes a failed create/import so it cannot be selected. The budget
    /// list shows a directory only while it holds `metadata.json`, so a failed
    /// delete falls back to removing that file, then to hiding the directory.
    /// Throws only when a selectable budget may remain.
    func discardUnfinishedBudget(fileID: String) throws {
        do {
            try deleteImportedBudget(fileID: fileID)
            return
        } catch {
            Self.logger.error("Unfinished budget cleanup failed; making it unselectable")
        }
        let directory = try budgetDirectory(fileID: fileID)
        let metadata = try metadataURL(fileID: fileID)
        guard fileManager.fileExists(atPath: metadata.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: metadata)
        } catch {
            let hidden = try containedURL(
                budgetRootURL().appending(path: ".Discarded-\(UUID().uuidString)", directoryHint: .isDirectory)
            )
            try fileManager.moveItem(at: directory, to: hidden)
        }
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

        let importedDatabase = try findDatabase(in: extractionURL)
        try BudgetDatabase.sanitizeUntrustedDatabase(at: importedDatabase)

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
        let extractor = UntrustedZipExtractor(
            limits: resourceLimits,
            fileManager: fileManager,
            volumeURL: applicationSupportURL
        )
        do {
            try extractor.extract(archiveAt: archiveURL, to: extractionURL) { candidate in
                try containedURL(candidate)
            }
        } catch let failure as UntrustedZipFailure {
            throw failure.localFirstError
        }
    }

    /// Mirrors upstream's download import (`cloud-storage.ts`): the archive
    /// root's `db.sqlite` wins, otherwise exactly one nested `db.sqlite`.
    /// Other names, including other `*.sqlite` files, are never a budget.
    private func findDatabase(in directory: URL) throws -> URL {
        let directory = try containedURL(directory)
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw LocalFirstError.missingImportedDatabase
        }

        var root: URL?
        var nested: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "db.sqlite" {
            let url = try containedURL(url)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            if url.deletingLastPathComponent() == directory {
                root = url
            } else {
                nested.append(url)
            }
        }
        if let root {
            return root
        }
        guard let only = nested.first else {
            throw LocalFirstError.missingImportedDatabase
        }
        guard nested.count == 1 else {
            throw LocalFirstError.invalidDownloadedBudget
        }
        return only
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
            try restoreBackupIfLiveMissing(fileID: fileID)
            return
        }
        try fileManager.moveItem(at: legacy, to: target)
    }

    /// A reimport that failed and could not restore its backup leaves no live
    /// directory. Every open and reimport entry point passes through here.
    private func restoreBackupIfLiveMissing(fileID: String) throws {
        let live = try budgetDirectory(fileID: fileID)
        let backup = try reimportBackupDirectory(fileID: fileID)
        guard !fileManager.fileExists(atPath: live.path),
              fileManager.fileExists(atPath: backup.path) else {
            return
        }
        do {
            try fileManager.moveItem(at: backup, to: live)
            Self.logger.notice("Restored a budget from its reimport backup")
        } catch {
            Self.logger.error("Restoring a budget from its reimport backup failed")
            throw LocalFirstError.reimportRollbackFailed
        }
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
        // Simulator metadata does not model device protection or backup policy.
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
