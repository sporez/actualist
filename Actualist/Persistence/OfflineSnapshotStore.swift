import Foundation

struct OfflineSnapshotStore {
    static let live = OfflineSnapshotStore()

    var fileManager: FileManager = .default

    func load(serverURLString: String, budgetID: String) -> ActualDataStoreSnapshot? {
        let fileURL = snapshotURL(serverURLString: serverURLString, budgetID: budgetID)
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        return try? JSONDecoder.actual.decode(ActualDataStoreSnapshot.self, from: data)
    }

    func save(_ snapshot: ActualDataStoreSnapshot, serverURLString: String, budgetID: String) {
        let fileURL = snapshotURL(serverURLString: serverURLString, budgetID: budgetID)
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.actual.encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            #if DEBUG
            print("Actualist snapshot save failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func snapshotURL(serverURLString: String, budgetID: String) -> URL {
        let baseDirectory = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        return baseDirectory
            .appendingPathComponent("Actualist", isDirectory: true)
            .appendingPathComponent("Snapshots", isDirectory: true)
            .appendingPathComponent("\(snapshotKey(serverURLString: serverURLString, budgetID: budgetID)).json")
    }

    private func snapshotKey(serverURLString: String, budgetID: String) -> String {
        let key = "\(ServerURLNormalizer.normalize(serverURLString))|\(budgetID)"
        return Data(key.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
