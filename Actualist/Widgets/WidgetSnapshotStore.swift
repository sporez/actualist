import Foundation

struct WidgetSnapshotStore: Sendable {
    var directoryURL: URL?

    static var live: WidgetSnapshotStore {
        WidgetSnapshotStore(
            directoryURL: FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: WidgetAppGroup.identifier
            )
        )
    }

    private var fileURL: URL? {
        directoryURL?.appending(path: "WidgetSnapshot.json")
    }

    func load() -> WidgetSnapshot? {
        guard let fileURL else {
            return nil
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        guard let snapshot = try? makeDecoder().decode(WidgetSnapshot.self, from: data) else {
            return nil
        }
        guard snapshot.schemaVersion == WidgetSnapshot.currentSchemaVersion else {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: WidgetSnapshot) throws {
        guard let directoryURL, let fileURL else {
            throw WidgetSnapshotStoreError.appGroupUnavailable
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try makeEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        var securedURL = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try securedURL.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        #endif
    }

    /// Reads and decodes off the main thread; the file is read and JSON-decoded in full.
    @concurrent
    func loadOffMain() async -> WidgetSnapshot? {
        load()
    }

    /// Encodes and writes off the main thread.
    @concurrent
    func saveOffMain(_ snapshot: WidgetSnapshot) async throws {
        try save(snapshot)
    }

    /// Returns whether a saved snapshot existed and was removed.
    @discardableResult
    func clear() -> Bool {
        guard let fileURL else {
            return false
        }
        return (try? FileManager.default.removeItem(at: fileURL)) != nil
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum WidgetSnapshotStoreError: Error {
    case appGroupUnavailable
}
