import Foundation

/// Lifecycle of the plaintext budget ZIPs the Settings export hands to
/// ShareLink. They live in `tmp/PortableExports/`, never alongside the budget
/// files, and are removed when the export is discarded, the session is erased,
/// or they age out. ShareLink reports no completion, so age is the backstop.
///
/// Protection class: `completeUntilFirstUserAuthentication`, the same class as
/// the cached budget files. `complete` would make the file unreadable if the
/// device locks while the share sheet or a receiving app is still copying it.
/// The file stays encrypted at rest until the first unlock after boot.
struct PortableExportFiles {
    static let staleAge: TimeInterval = 10 * 60
    static let directoryName = "PortableExports"
    /// The name a receiver sees. Fixed, so it never carries the budget's name
    /// (which privacy display settings may mask). Each export gets its own
    /// folder so the same name can repeat.
    static let archiveFileName = "Budget Export.zip"

    let directory: URL
    private let fileManager: FileManager

    init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        directory = temporaryDirectory.appending(path: Self.directoryName, directoryHint: .isDirectory)
        self.fileManager = fileManager
    }

    /// A fresh archive path, `<export directory>/<id>/Budget Export.zip`.
    func makeArchiveURL() throws -> URL {
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try protect(directory)
        try protect(folder)
        return folder.appending(path: Self.archiveFileName)
    }

    /// Applies the protection class to a finished export file.
    func protect(_ url: URL) throws {
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    /// Removes one export and its folder, but only inside the export directory.
    func discard(_ url: URL) {
        let folder = url.standardizedFileURL.deletingLastPathComponent()
        guard folder.deletingLastPathComponent() == directory.standardizedFileURL else {
            return
        }
        try? fileManager.removeItem(at: folder)
    }

    /// Removes export folders last modified more than `staleAge` before `now`.
    func sweepStale(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.staleAge)
        for url in contents() {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            // An unreadable date is treated as stale: nothing here is needed
            // beyond the share that created it.
            if modified.map({ $0 < cutoff }) ?? true {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    func removeAll() {
        for url in contents() {
            try? fileManager.removeItem(at: url)
        }
    }

    private func contents() -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        )) ?? []
    }
}
