import Foundation
import Testing
@testable import Actualist

/// Primary endpoint that serves the first request like the real server, then drops off.
private actor ConfirmThenUnreachableTransport: ActualSyncTransport {
    private let server: MerkleAwareSyncTransport
    private var calls = 0

    init(server: MerkleAwareSyncTransport) { self.server = server }

    func sync(data: Data, token: String) async throws -> Data {
        calls += 1
        guard calls == 1 else { throw ActualAPIError.transport(.cannotConnectToHost) }
        return try await server.sync(data: data, token: token)
    }
}

/// Fallback endpoint that records how many messages each request uploaded.
private actor UploadCountingTransport: ActualSyncTransport {
    private var uploadedCounts: [Int] = []

    func sync(data: Data, token: String) async throws -> Data {
        uploadedCounts.append(try ActualSync_SyncRequest(serializedBytes: data).messages.count)
        return try ActualSync_SyncResponse().serializedData()
    }

    func counts() -> [Int] { uploadedCounts }
}

private actor ConfirmationCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

extension LocalFirstActualStoreTests {
    private static let confirmationPhantom = "2026-07-04T11:00:00.000Z-0000-nodep"

    private var confirmationConfiguration: LocalFirstSyncConfiguration {
        LocalFirstSyncConfiguration(
            fileID: "file-1", groupID: "group-1", nodeID: "node1", encryptionKeyID: nil, encryptionContext: nil
        )
    }

    private func openConfirmationStore(
        primary: any ActualSyncTransport,
        fallback: (any ActualSyncTransport)? = nil
    ) async throws -> (bundle: OpenedWritableStoreBundle, database: BudgetDatabase) {
        let bundle = try await makeOpenedWritableStoreBundle { url in
            url.absoluteString == "https://fallback.example" ? (fallback ?? primary) : primary
        }
        try bundle.keychain.saveActualSyncToken("token")
        await bundle.store.syncClient.configure(confirmationConfiguration)
        let database = try bundle.store.requireDatabase(for: "group-1")
        _ = try await database.commitLocalSyncMessagesAndEnqueue([
            ActualSyncDecodedMessage(
                timestamp: "pending", dataset: "payees", row: "coffee", column: "name", serializedValue: "S:Coffee"
            )
        ])
        return (bundle, database)
    }

    @Test func confirmedUploadLeavesTheOutboxWhenTheMerkleRepullNeverConverges() async throws {
        let server = MerkleAwareSyncTransport()
        await server.addPhantom(Self.confirmationPhantom)
        let (bundle, database) = try await openConfirmationStore(primary: server)
        #expect(try await database.pendingLocalSyncMessageCount() == 1)

        await #expect(throws: LocalFirstError.syncOutOfSync) {
            _ = try await bundle.store.flushPendingLocalMessages(
                database: database, budgetID: "group-1", serverURLString: "https://sync.example"
            )
        }

        #expect(try await database.pendingLocalSyncMessageCount() == 0)
    }

    @Test func failoverAfterConfirmationPullsWithoutReuploadingDeletedRows() async throws {
        let server = MerkleAwareSyncTransport()
        await server.addPhantom(Self.confirmationPhantom)
        let fallback = UploadCountingTransport()
        let (bundle, database) = try await openConfirmationStore(
            primary: ConfirmThenUnreachableTransport(server: server),
            fallback: fallback
        )
        bundle.store.fallbackServerURLString = "https://fallback.example"

        let result = try await bundle.store.flushPendingLocalMessages(
            database: database, budgetID: "group-1", serverURLString: "https://sync.example"
        )

        #expect(result.pushedMessageCount == 1)
        let counts = await fallback.counts()
        #expect(!counts.isEmpty)
        #expect(counts.allSatisfy { $0 == 0 })
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
    }

    @Test func sessionTeardownBeforeConfirmationLeavesTheOutboxUntouched() async throws {
        let server = MerkleAwareSyncTransport()
        await server.addPhantom(Self.confirmationPhantom)
        let (bundle, database) = try await openConfirmationStore(primary: server)
        let store = bundle.store
        await server.setOnRequest { _ in await store.reset() }

        await #expect(throws: CancellationError.self) {
            _ = try await store.flushPendingLocalMessages(
                database: database, budgetID: "group-1", serverURLString: "https://sync.example"
            )
        }

        #expect(try await database.pendingLocalSyncMessageCount() == 1)
    }

    @Test func partialConfirmationThrowsWithoutReportingConfirmation() async throws {
        let database = try BudgetDatabase(databaseURL: makeSQLiteFixture())
        let client = SyncClient()
        await client.configure(confirmationConfiguration)
        let transport = FixedResponseSyncTransport(responseData: try ActualSync_SyncResponse().serializedData())
        let counter = ConfirmationCounter()

        await #expect(throws: LocalFirstError.syncUploadNotConfirmed(1)) {
            _ = try await client.pushAndPull(
                database: database,
                client: transport,
                token: "token",
                messages: [
                    ActualSyncDecodedMessage(
                        timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
                        dataset: "payees", row: "coffee", column: "name", serializedValue: "S:Coffee"
                    )
                ],
                since: "1970-01-01T00:00:00.000Z-0000-0000000000000000",
                onUploadConfirmed: { await counter.increment() }
            )
        }

        #expect(await counter.count == 0)
    }
}
