import Foundation
import GRDB
import Testing
@testable import Actualist

/// A sync server that, like Actual's, answers with its own merkle trie. Extra
/// "phantom" timestamps appear in that trie without a message behind them, so the
/// server can claim a history this client can never receive.
actor MerkleAwareSyncTransport: ActualSyncTransport {
    private var envelopes: [String: ActualSync_MessageEnvelope] = [:]
    private var phantomTimestamps: [String] = []
    private var sinceValues: [String] = []
    private var onRequest: (@Sendable (Int) async throws -> Void)?

    func seed(_ messages: [ActualSyncDecodedMessage]) throws {
        for message in messages {
            envelopes[message.timestamp] = try LocalFirstSyncMessageBuilder.envelope(for: message)
        }
    }

    func addPhantom(_ timestamp: String) {
        phantomTimestamps.append(timestamp)
    }

    func setOnRequest(_ hook: @escaping @Sendable (Int) async throws -> Void) {
        onRequest = hook
    }

    func requestCount() -> Int { sinceValues.count }

    func requestedSince() -> [String] { sinceValues }

    func merkle() -> MerkleTrie {
        var trie = MerkleTrie()
        for timestamp in envelopes.keys + phantomTimestamps {
            if let parsed = SyncTimestamp.parse(timestamp) { trie.insert(parsed) }
        }
        return trie.pruned()
    }

    func sync(data: Data, token: String) async throws -> Data {
        let request = try ActualSync_SyncRequest(serializedBytes: data)
        sinceValues.append(request.since)
        try await onRequest?(sinceValues.count)
        for message in request.messages where envelopes[message.timestamp] == nil {
            envelopes[message.timestamp] = message
        }
        var response = ActualSync_SyncResponse()
        response.messages = envelopes.values
            .filter { $0.timestamp > request.since }
            .sorted { $0.timestamp < $1.timestamp }
        response.merkle = merkle().jsonString
        return try response.serializedData()
    }
}

private actor SessionBudget {
    private var remaining: Int
    init(_ remaining: Int) { self.remaining = remaining }
    func allow() -> Bool {
        remaining -= 1
        return remaining >= 0
    }
}

extension LocalFirstActualStoreTests {
    private static let earlyFromNodeC = "2026-07-04T12:00:00.000Z-0000-nodec"
    private static let laterLocal = "2026-07-04T12:05:00.000Z-0000-nodeb"
    private static let phantom = "2026-07-04T11:00:00.000Z-0000-nodep"

    private func merkleMessage(_ timestamp: String, dataset: String, row: String, column: String, _ value: String)
        -> ActualSyncDecodedMessage {
        ActualSyncDecodedMessage(
            timestamp: timestamp, dataset: dataset, row: row, column: column, serializedValue: value
        )
    }

    private func merkleScalar(_ sql: String, _ url: URL) throws -> String? {
        try DatabaseQueue(path: url.path).read { try String.fetchOne($0, sql: sql) }
    }

    private var merkleConfiguration: LocalFirstSyncConfiguration {
        LocalFirstSyncConfiguration(
            fileID: "file-1", groupID: "group-1", nodeID: "node1", encryptionKeyID: nil, encryptionContext: nil
        )
    }

    private func openMerkleStore(_ transport: MerkleAwareSyncTransport) async throws -> OpenedWritableStoreBundle {
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")
        await bundle.store.syncClient.configure(merkleConfiguration)
        return bundle
    }

    @Test func olderMessageFromAnotherDeviceArrivesAfterLocalMaxAndTheTriesConverge() async throws {
        let early = merkleMessage(Self.earlyFromNodeC, dataset: "categories", row: "utilities", column: "name", "S:From node C")
        let later = merkleMessage(Self.laterLocal, dataset: "payees", row: "coffee", column: "name", "S:Later")
        let transport = MerkleAwareSyncTransport()
        try await transport.seed([early, later])
        let bundle = try await openMerkleStore(transport)
        let database = try bundle.store.requireDatabase(for: "group-1")
        _ = try await database.applyRemoteSyncMessages([later])
        let databaseURL = await database.databaseURL

        try await bundle.store.refresh(budgetID: "group-1", serverURLString: "https://sync.example")

        #expect(try merkleScalar("SELECT name FROM categories WHERE id = 'utilities'", databaseURL) == "From node C")
        #expect(try merkleScalar("SELECT name FROM payees WHERE id = 'coffee'", databaseURL) == "Later")
        #expect(try await database.merkleDivergence(from: await transport.merkle()) == nil)
        let requests = await transport.requestCount()
        #expect(requests >= 2)
        // The re-pull starts at or before the missing message, not at local MAX.
        #expect(try #require(await transport.requestedSince().last) <= Self.earlyFromNodeC)
    }

    @Test func guardThrowsAfterTenIdenticalDivergencesAndRebuildsOnceFirst() async throws {
        let later = merkleMessage(Self.laterLocal, dataset: "payees", row: "coffee", column: "name", "S:Later")
        let transport = MerkleAwareSyncTransport()
        try await transport.seed([later])
        await transport.addPhantom(Self.phantom)
        let bundle = try await openMerkleStore(transport)
        let database = try bundle.store.requireDatabase(for: "group-1")
        _ = try await database.applyRemoteSyncMessages([later])

        await #expect(throws: LocalFirstError.syncOutOfSync) {
            try await bundle.store.refresh(budgetID: "group-1", serverURLString: "https://sync.example")
        }

        // 1 initial + 9 re-pulls to reach count 10, a rebuild, then 10 more re-pulls.
        #expect(await transport.requestCount() == 20)
    }

    @Test func sessionTeardownStopsTheRepullLoop() async throws {
        let later = merkleMessage(Self.laterLocal, dataset: "transactions", row: "txn", column: "category", "S:Later")
        let url = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")
        _ = try await database.applyRemoteSyncMessages([later])
        let transport = MerkleAwareSyncTransport()
        try await transport.seed([later])
        await transport.addPhantom(Self.phantom)
        let client = SyncClient()
        await client.configure(merkleConfiguration)
        let budget = SessionBudget(7)

        await #expect(throws: CancellationError.self) {
            _ = try await client.pullAndApply(
                database: database, client: transport, token: "token", sessionIsCurrent: { await budget.allow() }
            )
        }

        #expect(await transport.requestCount() <= 3)
    }

    @Test func aLocalCommitDuringTheSyncResetsTheGuardCounter() async throws {
        let later = merkleMessage(Self.laterLocal, dataset: "transactions", row: "txn", column: "category", "S:Later")
        let url = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")
        _ = try await database.applyRemoteSyncMessages([later])
        let transport = MerkleAwareSyncTransport()
        try await transport.seed([later])
        await transport.addPhantom(Self.phantom)
        await transport.setOnRequest { request in
            guard request <= 12 else { return }
            _ = try await database.commitLocalSyncMessagesAndEnqueue([
                ActualSyncDecodedMessage(
                    timestamp: "pending", dataset: "transactions", row: "txn", column: "category",
                    serializedValue: "S:local-\(request)"
                )
            ])
        }
        let client = SyncClient()
        await client.configure(merkleConfiguration)

        await #expect(throws: LocalFirstError.syncOutOfSync) {
            _ = try await client.pullAndApply(
                database: database, client: transport, token: "token", sessionIsCurrent: { true }
            )
        }

        // Without the reset the guard trips after 10 requests and again after 20.
        #expect(await transport.requestCount() > 20)
    }
}
