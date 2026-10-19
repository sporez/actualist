import Foundation
import Testing
@testable import Actualist

/// Records how many messages each request carried and whether they were
/// encrypted, then forwards to the merkle-aware server.
private actor ResendRecordingTransport: ActualSyncTransport {
    let server: MerkleAwareSyncTransport
    private(set) var uploadCounts: [Int] = []
    private(set) var uploadedEnvelopes: [ActualSync_MessageEnvelope] = []

    init(server: MerkleAwareSyncTransport) { self.server = server }

    func sync(data: Data, token: String) async throws -> Data {
        let request = try ActualSync_SyncRequest(serializedBytes: data)
        uploadCounts.append(request.messages.count)
        uploadedEnvelopes.append(contentsOf: request.messages)
        return try await server.sync(data: data, token: token)
    }
}

/// Upstream `_fullSync` sends every local message after the divergence on each
/// re-pull round. These pin that behaviour: a backlog larger than one upload
/// batch, a commit during the sync, and messages the server lacks all converge
/// in one sync.
extension LocalFirstActualStoreTests {
    private static let resendBatchLimit = BudgetDatabase.syncUploadBatchLimit

    private func resendConfiguration(
        encryptionContext: ActualBudgetEncryptionContext? = nil
    ) -> LocalFirstSyncConfiguration {
        LocalFirstSyncConfiguration(
            fileID: "file-1", groupID: "group-1", nodeID: "node1",
            encryptionKeyID: encryptionContext?.keyID, encryptionContext: encryptionContext
        )
    }

    private func openResendStore(
        _ transport: any ActualSyncTransport,
        encryptionContext: ActualBudgetEncryptionContext? = nil,
        retryDelays: [Duration] = [.zero, .seconds(2), .seconds(8), .seconds(30)]
    ) async throws -> (OpenedWritableStoreBundle, BudgetDatabase) {
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in transport },
            pendingLocalMessageFlushRetryDelays: retryDelays
        )
        try bundle.keychain.saveActualSyncToken("token")
        await bundle.store.syncClient.configure(resendConfiguration(encryptionContext: encryptionContext))
        return (bundle, try bundle.store.requireDatabase(for: "group-1"))
    }

    private static func payeeDrafts(_ count: Int, prefix: String) -> [ActualSyncDecodedMessage] {
        (0..<count).map { index in
            ActualSyncDecodedMessage(
                timestamp: "pending", dataset: "payees", row: "\(prefix)-\(index)", column: "name",
                serializedValue: "S:Payee \(prefix) \(index)"
            )
        }
    }

    private func serverHeldCount(_ server: MerkleAwareSyncTransport) async throws -> Int {
        var request = ActualSync_SyncRequest()
        request.fileID = "file-1"
        request.groupID = "group-1"
        request.since = SyncTimestamp.zeroString
        let data = try await server.sync(data: try request.serializedData(), token: "token")
        return try ActualSync_SyncResponse(serializedBytes: data).messages.count
    }

    private func refreshResendStore(_ store: LocalFirstActualStore) async throws {
        try await store.refresh(budgetID: "group-1", serverURLString: "https://sync.example")
    }

    @Test(arguments: [501, 1_600])
    func oneRefreshUploadsAnOutboxLargerThanOneBatch(_ count: Int) async throws {
        let server = MerkleAwareSyncTransport()
        let transport = ResendRecordingTransport(server: server)
        let (bundle, database) = try await openResendStore(transport)
        _ = try await database.commitLocalSyncMessagesAndEnqueue(Self.payeeDrafts(count, prefix: "backlog"))

        try await refreshResendStore(bundle.store)

        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        #expect(try await database.merkleDivergence(from: await server.merkle()) == nil)
        #expect(try await serverHeldCount(server) == count)
        #expect(await transport.uploadCounts.allSatisfy { $0 <= Self.resendBatchLimit })
    }

    @Test func aCommitDuringTheUploadConvergesInTheSameRefresh() async throws {
        let server = MerkleAwareSyncTransport()
        let (bundle, database) = try await openResendStore(server)
        _ = try await database.commitLocalSyncMessagesAndEnqueue(Self.payeeDrafts(1, prefix: "first"))
        await server.setOnRequest { request in
            guard request == 1 else { return }
            _ = try await database.commitLocalSyncMessagesAndEnqueue(
                Self.payeeDrafts(1, prefix: "during-upload")
            )
        }

        try await refreshResendStore(bundle.store)

        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        #expect(try await database.merkleDivergence(from: await server.merkle()) == nil)
        #expect(try await serverHeldCount(server) == 2)
    }

    /// The pull re-sends the commit, so the server has it; its outbox row stays
    /// queued until the next flush confirms it.
    @Test func aCommitDuringThePullConvergesAndIsConfirmedByTheNextFlush() async throws {
        let server = MerkleAwareSyncTransport()
        let (bundle, database) = try await openResendStore(server)
        _ = try await database.commitLocalSyncMessagesAndEnqueue(Self.payeeDrafts(1, prefix: "first"))
        // Request 1 is the flush upload; request 2 is the pull after it.
        await server.setOnRequest { request in
            guard request == 2 else { return }
            _ = try await database.commitLocalSyncMessagesAndEnqueue(
                Self.payeeDrafts(1, prefix: "during-pull")
            )
        }

        try await refreshResendStore(bundle.store)

        #expect(try await database.merkleDivergence(from: await server.merkle()) == nil)
        #expect(try await serverHeldCount(server) == 2)
        #expect(try await database.pendingLocalSyncMessageCount() == 1)

        await server.setOnRequest { _ in }
        try await refreshResendStore(bundle.store)
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        #expect(try await serverHeldCount(server) == 2)
    }

    /// Messages this file holds that never reached the server (not queued) are
    /// found by the merkle comparison and re-sent from the divergence.
    @Test func messagesTheServerLacksAreResentFromTheDivergence() async throws {
        let server = MerkleAwareSyncTransport()
        let transport = ResendRecordingTransport(server: server)
        let (bundle, database) = try await openResendStore(transport)
        let held = (0..<1_200).map { index in
            ActualSyncDecodedMessage(
                timestamp: String(format: "2026-07-04T12:%02d:%02d.000Z-0000-000000000000000a", index / 60, index % 60),
                dataset: "payees", row: "held-\(index)", column: "name", serializedValue: "S:Held \(index)"
            )
        }
        _ = try await database.applyRemoteSyncMessages(held)

        try await refreshResendStore(bundle.store)

        #expect(try await database.merkleDivergence(from: await server.merkle()) == nil)
        #expect(try await serverHeldCount(server) == held.count)
        #expect(await transport.uploadCounts.allSatisfy { $0 <= Self.resendBatchLimit })
    }

    @Test func aResendOnAnEncryptedBudgetIsEncrypted() async throws {
        let context = ActualBudgetEncryptionContext(keyID: "test-key", keyData: Data(repeating: 7, count: 32))
        let server = MerkleAwareSyncTransport()
        let transport = ResendRecordingTransport(server: server)
        let (bundle, database) = try await openResendStore(transport, encryptionContext: context)
        let held = (0..<3).map { index in
            ActualSyncDecodedMessage(
                timestamp: "2026-07-04T12:00:0\(index).000Z-0000-000000000000000b",
                dataset: "payees", row: "secret-\(index)", column: "name", serializedValue: "S:Secret \(index)"
            )
        }
        _ = try await database.applyRemoteSyncMessages(held)

        try await refreshResendStore(bundle.store)

        let sent = await transport.uploadedEnvelopes
        #expect(sent.count == held.count)
        #expect(sent.allSatisfy { $0.isEncrypted })
        #expect(try await database.merkleDivergence(from: await server.merkle()) == nil)
    }

    @Test func aBackgroundRefreshWithALargeOutboxReportsARemoteTransaction() async throws {
        let server = MerkleAwareSyncTransport()
        let (bundle, database) = try await openResendStore(server)
        try await bundle.store.refreshAccountsWithBalances(budgetID: "group-1")
        _ = try await database.commitLocalSyncMessagesAndEnqueue(Self.payeeDrafts(501, prefix: "bg"))
        let timestamp = "2026-07-04T12:00:00.000Z-0000-00000000000000cc"
        let cells = [("acct", "S:savings"), ("date", "N:20260704"), ("amount", "N:-4321"), ("tombstone", "N:0")]
        try await server.seed(cells.enumerated().map { index, cell in
            ActualSyncDecodedMessage(
                timestamp: timestamp.replacingOccurrences(of: "-0000-", with: "-000\(index)-"),
                dataset: "transactions", row: "remote-tx", column: cell.0, serializedValue: cell.1
            )
        })

        let results = try await bundle.store.syncAndFindNewTransactions(
            budget: bundle.budget, serverURLString: "https://sync.example", openBudget: { _ in true }
        )

        #expect(results.flatMap(\.newTransactionIDs) == ["remote-tx"])
        #expect(bundle.store.accountDisplays(budgetID: "group-1").first { $0.id == "savings" }?.balance == -4321)
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
    }

    @Test func theScheduledFlushDrainsALargeOutboxWithoutAnError() async throws {
        let server = MerkleAwareSyncTransport()
        let (bundle, database) = try await openResendStore(
            server, retryDelays: [.zero, .milliseconds(10), .milliseconds(10), .milliseconds(10)]
        )
        try await refreshResendStore(bundle.store)
        let before = await server.requestCount()
        _ = try await database.commitLocalSyncMessagesAndEnqueue(Self.payeeDrafts(2_001, prefix: "scheduled"))

        await bundle.store.schedulePendingLocalMessageFlush(database: database, budgetID: "group-1")
        await bundle.store.syncLane.scheduledFlushTask?.value

        // Before the fix four failing attempts took 80 requests.
        #expect(await server.requestCount() - before <= 20)
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        #expect(bundle.store.syncStatus?.lastError == nil)
        #expect(try await serverHeldCount(server) == 2_001)
    }
}
