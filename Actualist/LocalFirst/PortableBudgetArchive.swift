import Foundation
import ZIPFoundation

struct PortableBudgetArchiveError: Error, Equatable {
    enum Stage: Equatable {
        case beforeExtraction
        case beforeInstall
    }

    enum Reason: Equatable {
        case unsafePath
        case symbolicLink
        case resourceLimit
        case insufficientStorage
        case truncated
        case missingDatabase
        case missingMetadata
        case splitDirectories
        case ambiguous
        case checksumMismatch
        case malformedMetadata
        case oversizedMetadata
        case integrity
        case unsupportedSchema
    }

    var stage: Stage
    var reason: Reason
}

extension UntrustedZipFailure {
    var portableRejection: PortableBudgetArchiveError {
        switch self {
        case .unsafePath:
            PortableBudgetArchiveError(stage: .beforeExtraction, reason: .unsafePath)
        case .symbolicLink:
            PortableBudgetArchiveError(stage: .beforeExtraction, reason: .symbolicLink)
        case .resourceLimit:
            PortableBudgetArchiveError(stage: .beforeExtraction, reason: .resourceLimit)
        case .insufficientStorage:
            PortableBudgetArchiveError(stage: .beforeExtraction, reason: .insufficientStorage)
        case .checksumMismatch, .sizeMismatch:
            PortableBudgetArchiveError(stage: .beforeInstall, reason: .checksumMismatch)
        }
    }
}

/// Allowlisted portable metadata. Cloud, group, key, user, device, token,
/// password, and path fields are never written. `id` is a fresh archive
/// identity, not the source budget id. `resetClock` is always true.
struct PortableBudgetMetadata: Equatable, Sendable {
    static let archivedKeys = ["id", "budgetName", "resetClock"]

    let id: String
    let budgetName: String
    let resetClock: Bool

    func encodedJSON() throws -> Data {
        let object: [String: Any] = [
            "id": id,
            "budgetName": budgetName,
            "resetClock": resetClock
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// Validates an untrusted portable zip and builds a sanitized export.
///
/// Validation stages into the caller-provided directory and never installs
/// through `BudgetFileManager` or `reimportBudget`. A successful result keeps
/// only the co-located `db.sqlite` + allowlisted `metadata.json` pair.
struct PortableBudgetArchive {
    static let defaultMaximumMetadataBytes = 64 * 1_024

    let limits: LocalFirstResourceLimits
    let fileManager: FileManager
    let maximumMetadataBytes: Int
    let identityGenerator: @Sendable () -> String

    init(
        limits: LocalFirstResourceLimits = .standard,
        fileManager: FileManager = .default,
        maximumMetadataBytes: Int = defaultMaximumMetadataBytes,
        identityGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.limits = limits
        self.fileManager = fileManager
        self.maximumMetadataBytes = maximumMetadataBytes
        self.identityGenerator = identityGenerator
    }

    struct ValidatedArchive: Equatable, Sendable {
        let databaseURL: URL
        let metadataURL: URL
        let metadata: PortableBudgetMetadata
    }

    func validate(
        archiveAt archiveURL: URL,
        stagingDirectory: URL
    ) throws -> ValidatedArchive {
        let compressedSize: UInt64
        do {
            compressedSize = try UntrustedZipExtractor.fileSize(
                at: archiveURL,
                fileManager: fileManager
            )
        } catch {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .truncated)
        }
        guard compressedSize <= limits.maximumCompressedBudgetBytes else {
            throw PortableBudgetArchiveError(stage: .beforeExtraction, reason: .resourceLimit)
        }

        let work = stagingDirectory.appending(
            path: "portable-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        var succeeded = false
        defer {
            if !succeeded {
                try? fileManager.removeItem(at: work)
            }
        }

        let raw = work.appending(path: "raw", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: raw, withIntermediateDirectories: true)
        let extractor = UntrustedZipExtractor(
            limits: limits,
            fileManager: fileManager,
            volumeURL: stagingDirectory
        )
        do {
            try extractor.extract(archiveAt: archiveURL, to: raw) { candidate in
                try containedURL(candidate, root: raw)
            }
        } catch let failure as UntrustedZipFailure {
            throw failure.portableRejection
        } catch is Archive.ArchiveError {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .truncated)
        } catch {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .truncated)
        }

        let pair = try selectPair(in: raw)
        let metadata = try sanitizedMetadata(at: pair.metadataURL, avoiding: pair.embeddedIdentity)
        try BudgetDatabase.validatePortableDatabase(at: pair.databaseURL)

        let validated = work.appending(path: "validated", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: validated, withIntermediateDirectories: true)
        let databaseURL = validated.appending(path: "db.sqlite")
        let metadataURL = validated.appending(path: "metadata.json")
        try fileManager.copyItem(at: pair.databaseURL, to: databaseURL)
        try metadata.encodedJSON().write(to: metadataURL, options: .atomic)
        try fileManager.removeItem(at: raw)

        succeeded = true
        return ValidatedArchive(
            databaseURL: databaseURL,
            metadataURL: metadataURL,
            metadata: metadata
        )
    }

    func export(
        database: BudgetDatabase,
        budgetName: String,
        sourceIdentity: String,
        to archiveURL: URL
    ) async throws -> PortableBudgetMetadata {
        let metadata = try Self.metadata(
            budgetName: budgetName,
            identity: freshIdentity(avoiding: sourceIdentity)
        )
        let scratch = fileManager.temporaryDirectory.appending(
            path: "portable-export-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let databaseURL = scratch.appending(path: "db.sqlite")
        let metadataURL = scratch.appending(path: "metadata.json")
        try await database.writePortableSnapshot(to: databaseURL)
        try metadata.encodedJSON().write(to: metadataURL, options: .atomic)
        try writeRootPairZip(databaseURL: databaseURL, metadataURL: metadataURL, to: archiveURL)
        return metadata
    }

    /// Builds an upload payload from an already validated pair: the same
    /// root-pair layout the portable export writes (`db.sqlite` +
    /// allowlisted `metadata.json`, deflate). The staged metadata is the
    /// fresh-identity JSON `PortableBudgetArchive` wrote during validation,
    /// so the server copy never carries the source budget's embedded
    /// identity. The zip lives inside the caller-provided directory; the
    /// caller owns its cleanup.
    func sanitizedArchiveBytes(
        databaseAt databaseURL: URL,
        metadataAt metadataURL: URL,
        stagingDirectory: URL
    ) throws -> Data {
        let zipURL = stagingDirectory.appending(
            path: "sanitized-\(UUID().uuidString).zip",
            directoryHint: .notDirectory
        )
        try writeRootPairZip(databaseURL: databaseURL, metadataURL: metadataURL, to: zipURL)
        return try Data(contentsOf: zipURL)
    }

    private struct ExtractedPair {
        let databaseURL: URL
        let metadataURL: URL
        let embeddedIdentity: String?
    }

    private func selectPair(in directory: URL) throws -> ExtractedPair {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .missingDatabase)
        }

        var databases: [URL] = []
        var metadataFiles: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }
            switch url.lastPathComponent {
            case "db.sqlite":
                databases.append(url)
            case "metadata.json":
                metadataFiles.append(url)
            default:
                break
            }
        }

        if databases.isEmpty {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .missingDatabase)
        }
        if metadataFiles.isEmpty {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .missingMetadata)
        }
        if databases.count != 1 || metadataFiles.count != 1 {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .ambiguous)
        }

        let databaseDirectory = databases[0].deletingLastPathComponent().standardizedFileURL
        let metadataDirectory = metadataFiles[0].deletingLastPathComponent().standardizedFileURL
        guard databaseDirectory == metadataDirectory else {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .splitDirectories)
        }
        return ExtractedPair(
            databaseURL: databases[0],
            metadataURL: metadataFiles[0],
            embeddedIdentity: embeddedIdentity(at: metadataFiles[0])
        )
    }

    private func sanitizedMetadata(at url: URL, avoiding embeddedIdentity: String?) throws -> PortableBudgetMetadata {
        let size = try UntrustedZipExtractor.fileSize(at: url, fileManager: fileManager)
        guard size <= UInt64(maximumMetadataBytes) else {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .oversizedMetadata)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumMetadataBytes else {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .oversizedMetadata)
        }
        let budgetName = try budgetName(in: data)
        var forbidden: Set<String> = []
        if let embeddedIdentity, !embeddedIdentity.isEmpty {
            forbidden.insert(embeddedIdentity)
        }
        return try Self.metadata(
            budgetName: budgetName,
            identity: freshIdentity(avoiding: forbidden)
        )
    }

    private func embeddedIdentity(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let id = object["id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    private func budgetName(in data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["budgetName"] as? String else {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .malformedMetadata)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .malformedMetadata)
        }
        return trimmed
    }

    private func freshIdentity(avoiding forbidden: String) -> String {
        freshIdentity(avoiding: [forbidden])
    }

    private func freshIdentity(avoiding forbidden: Set<String>) -> String {
        for _ in 0..<8 {
            let candidate = identityGenerator()
            if isAcceptableIdentity(candidate, avoiding: forbidden) {
                return candidate
            }
        }
        let fallback = UUID().uuidString
        if isAcceptableIdentity(fallback, avoiding: forbidden) {
            return fallback
        }
        return fallback + "-portable"
    }

    private func isAcceptableIdentity(_ value: String, avoiding forbidden: Set<String>) -> Bool {
        guard !value.isEmpty,
              !forbidden.contains(value),
              !value.contains("\0"),
              !value.contains("/"),
              !value.contains("\\"),
              value != ".",
              value != ".." else {
            return false
        }
        return true
    }

    private static func metadata(budgetName: String, identity: String) throws -> PortableBudgetMetadata {
        let trimmed = budgetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .malformedMetadata)
        }
        return PortableBudgetMetadata(id: identity, budgetName: trimmed, resetClock: true)
    }

    private func containedURL(_ candidate: URL, root: URL) throws -> URL {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.pathComponents.starts(with: root.pathComponents),
              resolved.pathComponents.count > root.pathComponents.count else {
            throw UntrustedZipFailure.unsafePath
        }
        return resolved
    }

    private func writeRootPairZip(databaseURL: URL, metadataURL: URL, to archiveURL: URL) throws {
        let temporary = archiveURL.appendingPathExtension("partial")
        defer { try? fileManager.removeItem(at: temporary) }
        if fileManager.fileExists(atPath: temporary.path) {
            try fileManager.removeItem(at: temporary)
        }
        let archive = try Archive(url: temporary, accessMode: .create)
        try addFile(databaseURL, name: "db.sqlite", to: archive)
        try addFile(metadataURL, name: "metadata.json", to: archive)
        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }
        try fileManager.moveItem(at: temporary, to: archiveURL)
    }

    private func addFile(_ url: URL, name: String, to archive: Archive) throws {
        let data = try Data(contentsOf: url)
        try archive.addEntry(
            with: name,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            let end = min(start + size, data.count)
            return data.subdata(in: start..<end)
        }
    }
}
