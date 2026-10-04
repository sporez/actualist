import Foundation
import ZIPFoundation

/// Failures from the shared untrusted-zip checks. Download import maps these
/// back to `LocalFirstError`. Portable validation maps them to its own stages.
enum UntrustedZipFailure: Error, Equatable {
    case unsafePath
    case symbolicLink
    case resourceLimit
    case insufficientStorage
    case checksumMismatch
    case sizeMismatch

    var localFirstError: LocalFirstError {
        switch self {
        case .unsafePath, .symbolicLink, .checksumMismatch, .sizeMismatch:
            .invalidDownloadedBudget
        case .resourceLimit:
            .remoteDataLimitExceeded
        case .insufficientStorage:
            .insufficientStorage
        }
    }
}

/// Path, entry, checksum, and disk-reserve checks for an untrusted zip.
///
/// `BudgetFileManager.extractArchive` and portable validation both call this so
/// the download path does not grow a second copy. The caller resolves each
/// destination; this type does not install a budget or choose `db.sqlite`.
struct UntrustedZipExtractor {
    let limits: LocalFirstResourceLimits
    let fileManager: FileManager
    let volumeURL: URL

    static func fileSize(at url: URL, fileManager: FileManager) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw UntrustedZipFailure.sizeMismatch
        }
        return number.uint64Value
    }

    func extract(
        archiveAt archiveURL: URL,
        to extractionURL: URL,
        resolvingDestination: (URL) throws -> URL
    ) throws {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        let entries = Array(archive)
        guard entries.count <= limits.maximumArchiveEntryCount else {
            throw UntrustedZipFailure.resourceLimit
        }

        var totalExpandedBytes: UInt64 = 0
        for entry in entries {
            try validateArchivePath(entry.path)
            guard entry.type != .symlink else {
                throw UntrustedZipFailure.symbolicLink
            }
            guard entry.uncompressedSize <= limits.maximumArchiveEntryBytes else {
                throw UntrustedZipFailure.resourceLimit
            }
            let (nextTotal, overflow) = totalExpandedBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, nextTotal <= limits.maximumExpandedBudgetBytes else {
                throw UntrustedZipFailure.resourceLimit
            }
            totalExpandedBytes = nextTotal
        }

        try requireAvailableDiskSpace(forExpandedBytes: totalExpandedBytes)

        var remainingBytes = limits.maximumExpandedBudgetBytes
        for entry in entries {
            let destination = try resolvingDestination(
                extractionURL.appending(path: entry.path)
            )
            switch entry.type {
            case .directory:
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            case .file:
                remainingBytes -= try extractFile(
                    entry,
                    from: archive,
                    to: destination,
                    remainingBudgetBytes: remainingBytes
                )
            case .symlink:
                throw UntrustedZipFailure.symbolicLink
            }
        }
    }

    /// Streams one file entry into a handle this type opened. ZIPFoundation's
    /// `extract(_:to:)` trusts the declared sizes and writes everything before
    /// any size check, so a small archive can fill the disk. Here the running
    /// count stops the write at the declared entry size and at the remaining
    /// archive budget. A failed entry leaves no partial file behind.
    private func extractFile(
        _ entry: Entry,
        from archive: Archive,
        to destination: URL,
        remainingBudgetBytes: UInt64
    ) throws -> UInt64 {
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        var written: UInt64 = 0
        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            let checksum = try archive.extract(entry, skipCRC32: false, progress: nil) { chunk in
                let (next, overflow) = written.addingReportingOverflow(UInt64(chunk.count))
                guard !overflow, next <= entry.uncompressedSize else {
                    throw UntrustedZipFailure.sizeMismatch
                }
                guard next <= remainingBudgetBytes else {
                    throw UntrustedZipFailure.resourceLimit
                }
                try handle.write(contentsOf: chunk)
                written = next
            }
            guard checksum == entry.checksum else {
                throw UntrustedZipFailure.checksumMismatch
            }
            guard written == entry.uncompressedSize else {
                throw UntrustedZipFailure.sizeMismatch
            }
            return written
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
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
            throw UntrustedZipFailure.unsafePath
        }
        guard components.count <= limits.maximumArchivePathDepth else {
            throw UntrustedZipFailure.resourceLimit
        }
        if let first = components.first,
           first.count == 2,
           first.last == ":" {
            throw UntrustedZipFailure.unsafePath
        }
    }

    private func requireAvailableDiskSpace(forExpandedBytes expandedBytes: UInt64) throws {
        guard expandedBytes <= UInt64(Int64.max) else {
            throw UntrustedZipFailure.resourceLimit
        }
        // The staged archive is already included in available capacity.
        let withReserve = Int64(expandedBytes)
            .addingReportingOverflow(limits.minimumFreeDiskReserveBytes)
        let availableBytes = try? volumeURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        guard !withReserve.overflow,
              let availableBytes,
              availableBytes >= withReserve.partialValue else {
            throw UntrustedZipFailure.insufficientStorage
        }
    }
}
