import Foundation
import Testing
import ZIPFoundation
@testable import Actualist

/// Streaming-extraction coverage for `UntrustedZipExtractor`: a zip whose
/// declared sizes lie must be stopped while writing, not after the fact.
struct UntrustedZipExtractorTests {
    private let fileManager = FileManager.default

    private func makeWorkspace() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appending(path: "UntrustedZip-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExtractor(
        in workspace: URL,
        maximumExpandedBudgetBytes: UInt64 = 64 * 1_024 * 1_024,
        maximumArchiveEntryBytes: UInt64 = 64 * 1_024 * 1_024
    ) -> UntrustedZipExtractor {
        UntrustedZipExtractor(
            limits: LocalFirstResourceLimits(
                maximumCompressedBudgetBytes: 64 * 1_024 * 1_024,
                maximumExpandedBudgetBytes: maximumExpandedBudgetBytes,
                maximumArchiveEntryBytes: maximumArchiveEntryBytes,
                maximumArchiveEntryCount: 10,
                maximumArchivePathDepth: 4,
                minimumFreeDiskReserveBytes: 0,
                maximumSyncResponseBytes: 1_024
            ),
            fileManager: fileManager,
            volumeURL: workspace
        )
    }

    private func writeArchive(at url: URL, entries: [(String, Data)]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<min(start + size, data.count))
            }
        }
    }

    /// Rewrites the declared uncompressed size (little-endian UInt32) of the
    /// first entry in both the local header (+22) and central directory (+24),
    /// found by signature scan. The stored CRC is left as written.
    private func patchDeclaredSize(of archiveURL: URL, to size: UInt32) throws {
        var bytes = try Data(contentsOf: archiveURL)
        func offsets(of signature: [UInt8]) -> [Int] {
            var found: [Int] = []
            let last = bytes.count - signature.count
            var index = 0
            while index <= last {
                if bytes[bytes.startIndex + index] == signature[0],
                   Array(bytes[(bytes.startIndex + index)..<(bytes.startIndex + index + signature.count)]) == signature {
                    found.append(index)
                }
                index += 1
            }
            return found
        }
        let local = try #require(offsets(of: [0x50, 0x4B, 0x03, 0x04]).first)
        let central = try #require(offsets(of: [0x50, 0x4B, 0x01, 0x02]).first)
        for position in [local + 22, central + 24] {
            for shift in 0..<4 {
                bytes[position + shift] = UInt8((size >> (8 * UInt32(shift))) & 0xFF)
            }
        }
        try bytes.write(to: archiveURL)
    }

    private func totalBytes(under directory: URL) -> UInt64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in enumerator {
            total += UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    @Test func declaredSizeLieStopsWritingAtTheDeclaredSize() throws {
        let workspace = try makeWorkspace()
        let archiveURL = workspace.appending(path: "bomb.zip")
        let eightMiB = 8 * 1_024 * 1_024
        try writeArchive(at: archiveURL, entries: [("db.sqlite", Data(count: eightMiB))])
        try patchDeclaredSize(of: archiveURL, to: 1_024)
        let extraction = workspace.appending(path: "out", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: extraction, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            try makeExtractor(in: workspace).extract(
                archiveAt: archiveURL,
                to: extraction
            ) { $0 }
        }
        #expect(totalBytes(under: extraction) <= 1_024 + 64 * 1_024)
        #expect(!fileManager.fileExists(atPath: extraction.appending(path: "db.sqlite").path))
    }

    @Test func normalArchiveStillExtractsFilesAndDirectories() throws {
        let workspace = try makeWorkspace()
        let archiveURL = workspace.appending(path: "ok.zip")
        let payload = Data((0..<50_000).map { UInt8($0 % 251) })
        try writeArchive(at: archiveURL, entries: [("nested/dir/db.sqlite", payload), ("metadata.json", Data("{}".utf8))])
        let extraction = workspace.appending(path: "out", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: extraction, withIntermediateDirectories: true)

        try makeExtractor(in: workspace).extract(archiveAt: archiveURL, to: extraction) { $0 }

        #expect(try Data(contentsOf: extraction.appending(path: "nested/dir/db.sqlite")) == payload)
        #expect(try Data(contentsOf: extraction.appending(path: "metadata.json")) == Data("{}".utf8))
    }

    @Test func declaredTotalOverBudgetAcrossTwoEntriesThrows() throws {
        let workspace = try makeWorkspace()
        let archiveURL = workspace.appending(path: "two.zip")
        try writeArchive(at: archiveURL, entries: [
            ("a.bin", Data(count: 1_000)),
            ("b.bin", Data(count: 1_000))
        ])
        let extraction = workspace.appending(path: "out", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: extraction, withIntermediateDirectories: true)

        #expect(throws: UntrustedZipFailure.resourceLimit) {
            try makeExtractor(in: workspace, maximumExpandedBudgetBytes: 1_500).extract(
                archiveAt: archiveURL,
                to: extraction
            ) { $0 }
        }
    }

    @Test func checksumMismatchStillThrowsAndRemovesThePartialFile() throws {
        let workspace = try makeWorkspace()
        let archiveURL = workspace.appending(path: "crc.zip")
        try writeArchive(at: archiveURL, entries: [("db.sqlite", Data(repeating: 7, count: 4_096))])
        // Flip one stored-CRC byte in the central directory (+16) and local header (+14).
        var bytes = try Data(contentsOf: archiveURL)
        let central = try #require(bytes.range(of: Data([0x50, 0x4B, 0x01, 0x02]))).lowerBound
        let local = try #require(bytes.range(of: Data([0x50, 0x4B, 0x03, 0x04]))).lowerBound
        bytes[central + 16] ^= 0xFF
        bytes[local + 14] ^= 0xFF
        try bytes.write(to: archiveURL)
        let extraction = workspace.appending(path: "out", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: extraction, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            try makeExtractor(in: workspace).extract(archiveAt: archiveURL, to: extraction) { $0 }
        }
        #expect(!fileManager.fileExists(atPath: extraction.appending(path: "db.sqlite").path))
    }

    @Test func existingDestinationFileIsNeverOverwritten() throws {
        let workspace = try makeWorkspace()
        let archiveURL = workspace.appending(path: "ok.zip")
        try writeArchive(at: archiveURL, entries: [("db.sqlite", Data("new".utf8))])
        let extraction = workspace.appending(path: "out", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: extraction, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: extraction.appending(path: "db.sqlite"))

        #expect(throws: (any Error).self) {
            try makeExtractor(in: workspace).extract(archiveAt: archiveURL, to: extraction) { $0 }
        }
        #expect(try Data(contentsOf: extraction.appending(path: "db.sqlite")) == Data("old".utf8))
    }
}
