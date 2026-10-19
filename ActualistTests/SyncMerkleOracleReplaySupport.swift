import CryptoKit
import Foundation
import GRDB
@testable import Actualist

/// Replays a SyncMerkle oracle case through the production sync: a starter
/// budget seeded with the case's client messages (pending ones queued in the
/// outbox), the merkle-aware fake server seeded with the server's, the case's
/// mid-sync events fired on the Nth request, then `LocalFirstActualStore.refresh`
/// (flush, then pull). See `scripts/parity/sync-merkle/README.md` ("Swift replay").
@MainActor
enum SyncMerkleOracleReplay {
    struct Observed {
        let outcome: String
        let serverTimestamps: [String]
        let clientTimestamps: [String]
        let merkleEqual: Bool
        let clientPayees: [String]
        /// Timestamps this client minted for mid-sync commits, with their rows.
        let mintedRows: [String: String]
    }

    private static let fileID = "file-1"
    private static let groupID = "group-1"

    static func replay(_ entry: [String: Any], header: [String: Any]) async throws -> Observed {
        let permit = await OracleReplayGate.shared.acquire()
        defer { permit.release() }
        let message = try OracleJSON.object(header["message"], "message")
        let dataset = try OracleJSON.string(message, "dataset")
        let column = try OracleJSON.string(message, "column")
        let clientNode = try OracleJSON.string(message, "clientNode")
        let setup = try OracleJSON.object(entry["setup"], "setup")
        func messages(_ key: String) throws -> [ActualSyncDecodedMessage] {
            try OracleJSON.objects(setup[key], key).map { item in
                ActualSyncDecodedMessage(
                    timestamp: try OracleJSON.string(item, "timestamp"),
                    dataset: dataset,
                    row: try OracleJSON.string(item, "row"),
                    column: column,
                    serializedValue: try OracleJSON.string(item, "value")
                )
            }
        }
        let shared = try messages("shared")
        let serverOnly = try messages("serverOnly")
        let pending = try messages("clientPending")
        let unsent = try messages("clientUnsent")
        let phantom = setup["phantom"] as? [String] ?? []
        let lastSynced = try OracleJSON.string(setup, "lastSynced")

        let root = FileManager.default.temporaryDirectory
            .appending(path: "SyncMerkleOracleReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = BudgetFileManager(applicationSupportURL: root)
        try FileManager.default.createDirectory(
            at: try fileManager.budgetDirectory(fileID: fileID), withIntermediateDirectories: true
        )
        let databaseURL = try fileManager.databaseURL(fileID: fileID)
        let seedDatabase = try await OracleReplayDatabase.starter(at: databaseURL, localNodeID: clientNode)
        let clientHeld = shared + pending + unsent
        if !clientHeld.isEmpty {
            _ = try await seedDatabase.applyRemoteSyncMessages(clientHeld)
        }
        try await queuePending(pending, baseTimestamp: lastSynced, databaseURL: databaseURL)
        try JSONEncoder.actual.encode(LocalFirstBudgetMetadata(
            localBudgetID: fileID, cloudFileID: fileID, groupID: groupID,
            budgetName: "Sync Merkle Replay", encryptionKeyID: nil, nodeID: clientNode
        )).write(to: fileManager.metadataURL(fileID: fileID))

        let server = MerkleAwareSyncTransport()
        try await server.seed(shared + serverOnly)
        for timestamp in phantom { await server.addPhantom(timestamp) }
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests", account: UUID().uuidString, backend: FakeKeychainBackend()
        )
        try keychain.saveActualSyncToken("token")
        let store = LocalFirstActualStore(
            keychain: keychain, fileManager: fileManager, syncTransportFactory: { _ in server }
        )
        let budget = ActualBudget(budgetID: fileID, cloudFileId: fileID, groupId: groupID, name: "Sync Merkle Replay", state: nil)
        _ = try await store.openCachedBudget(budget)
        await store.syncClient.configure(LocalFirstSyncConfiguration(
            fileID: fileID, groupID: groupID, nodeID: clientNode, encryptionKeyID: nil, encryptionContext: nil
        ))
        let database = try store.requireDatabase(for: budget.syncID)

        // Only events upstream fired: one keyed to a request upstream never made
        // did not happen in the oracle run. Actualist makes more requests per sync
        // (separate flush and pull, upload confirmation), so it would reach them.
        let upstreamRequestCount = try OracleJSON.objects(
            OracleJSON.object(entry["result"], "result")["requests"], "requests"
        ).count
        let events = try OracleJSON.objects(entry["during"], "during").filter { event in
            (event["atRequest"] as? Int ?? Int.max) <= upstreamRequestCount
        }
        func atRequest(_ event: [String: Any]) throws -> Int {
            guard let request = event["atRequest"] as? Int else {
                throw OracleReplayError.malformedFixture("a during event has no atRequest")
            }
            return request
        }
        let serverEvents = try Dictionary(grouping: events.filter { $0["serverReceives"] != nil }, by: atRequest)
            .mapValues { group in
            try group.flatMap { event in
                try OracleJSON.objects(event["serverReceives"], "serverReceives").map { item in
                    ActualSyncDecodedMessage(
                        timestamp: try OracleJSON.string(item, "timestamp"), dataset: dataset,
                        row: try OracleJSON.string(item, "row"), column: column,
                        serializedValue: try OracleJSON.string(item, "value")
                    )
                }
            }
        }
        let commitEvents = try Dictionary(grouping: events.filter { $0["clientCommits"] != nil }, by: atRequest)
            .mapValues { group in
            try group.flatMap { event in
                try OracleJSON.objects(event["clientCommits"], "clientCommits").map { item in
                    ActualSyncDecodedMessage(
                        timestamp: "pending", dataset: try OracleJSON.string(item, "dataset"),
                        row: try OracleJSON.string(item, "row"), column: try OracleJSON.string(item, "column"),
                        serializedValue: try OracleJSON.string(item, "value")
                    )
                }
            }
        }
        await server.setOnRequest { request in
            if let received = serverEvents[request] { try await server.seed(received) }
            if let drafts = commitEvents[request] { _ = try await database.commitLocalSyncMessagesAndEnqueue(drafts) }
        }

        let outcome: String
        do {
            try await store.refresh(budgetID: budget.syncID, serverURLString: "https://sync.example")
            outcome = "ok"
        } catch LocalFirstError.syncOutOfSync {
            outcome = "out-of-sync"
        } catch {
            outcome = "error:\(error)"
        }
        await server.setOnRequest { _ in }

        let clientRows = try await readStrings("SELECT timestamp || char(9) || row FROM messages_crdt", databaseURL)
            .map { $0.split(separator: "\t", maxSplits: 1).map(String.init) }
        let clientTimestamps = clientRows.map { $0[0] }
        let known = Set((clientHeld + serverOnly + serverEvents.values.flatMap { $0 }).map(\.timestamp))
        return Observed(
            outcome: outcome,
            serverTimestamps: try await serverTimestamps(server),
            clientTimestamps: clientTimestamps,
            merkleEqual: try await database.merkleDivergence(from: await server.merkle()) == nil,
            clientPayees: try await readStrings(
                "SELECT id || char(9) || COALESCE(name, '') FROM payees WHERE id LIKE 'p-%'", databaseURL
            ),
            mintedRows: Dictionary(uniqueKeysWithValues: clientRows.filter { !known.contains($0[0]) }.map { ($0[0], $0[1]) })
        )
    }

    /// The fixture's list digest: lowercase hex SHA-256 of the sorted entries
    /// joined by "\n" (see the generator README).
    nonisolated static func digest(_ entries: [String]) -> String {
        SHA256.hash(data: Data(entries.sorted().joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func serverTimestamps(_ server: MerkleAwareSyncTransport) async throws -> [String] {
        var request = ActualSync_SyncRequest()
        request.fileID = fileID
        request.groupID = groupID
        request.since = SyncTimestamp.zeroString
        let data = try await server.sync(data: try request.serializedData(), token: "token")
        return try ActualSync_SyncResponse(serializedBytes: data).messages.map(\.timestamp)
    }

    /// Pending client messages are queued like local writes that have not been
    /// uploaded, with the case's last synced timestamp as their base.
    @concurrent
    private static func queuePending(
        _ pending: [ActualSyncDecodedMessage], baseTimestamp: String, databaseURL: URL
    ) async throws {
        guard !pending.isEmpty else { return }
        try await DatabaseQueue(path: databaseURL.path).write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS actualist_outbox (
                    timestamp TEXT PRIMARY KEY, dataset TEXT NOT NULL, row TEXT NOT NULL,
                    column TEXT NOT NULL, value TEXT NOT NULL, base_timestamp TEXT NOT NULL,
                    created_at TEXT NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0,
                    last_attempt_at TEXT, last_error TEXT
                )
                """)
            for message in pending {
                try db.execute(
                    sql: """
                        INSERT INTO actualist_outbox
                            (timestamp, dataset, row, column, value, base_timestamp, created_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        message.timestamp, message.dataset, message.row, message.column,
                        message.serializedValue, baseTimestamp, baseTimestamp,
                    ]
                )
            }
        }
    }

    @concurrent
    private static func readStrings(_ sql: String, _ url: URL) async throws -> [String] {
        try await DatabaseQueue(path: url.path).read { try String.fetchAll($0, sql: sql) }
    }
}
