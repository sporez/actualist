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

        var extractedBytes: UInt64 = 0
        for entry in entries {
            let destination = try resolvingDestination(
                extractionURL.appending(path: entry.path)
            )
            let checksum = try archive.extract(entry, to: destination)
            guard checksum == entry.checksum else {
                throw UntrustedZipFailure.checksumMismatch
            }
            if entry.type == .file {
                let actualSize = try Self.fileSize(at: destination, fileManager: fileManager)
                guard actualSize == entry.uncompressedSize else {
                    throw UntrustedZipFailure.sizeMismatch
                }
                let (nextExtracted, overflow) = extractedBytes.addingReportingOverflow(actualSize)
                guard !overflow, nextExtracted <= limits.maximumExpandedBudgetBytes else {
                    throw UntrustedZipFailure.resourceLimit
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
