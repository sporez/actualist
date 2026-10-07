import Foundation
import Synchronization
import Testing
@testable import Actualist

/// CA-09: cached transports must not re-read custom headers from Keychain, and
/// one sync operation reads the sync token once.
@MainActor
struct SyncKeychainReadTests {
    private static let headersAccount = "custom-http-headers"
    private let fixtures = LocalFirstActualStoreTests()

    private func makeBundle(
        backend: FakeKeychainBackend,
        creations: SyncCreationCounter
    ) async throws -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in creations.next() },
            keychainBackend: backend
        )
        try bundle.keychain.saveActualSyncToken("token")
        return bundle
    }

    @Test func cachedTransportDoesNotReadHeadersFromKeychain() async throws {
        let backend = FakeKeychainBackend()
        let creations = SyncCreationCounter()
        let bundle = try await makeBundle(backend: backend, creations: creations)
        let url = "https://sync.example"

        _ = try await bundle.store.withSyncFailover(serverURLString: url) { transport in
            _ = try await transport.sync(data: Data(), token: "token")
        }
        let readsAfterFirst = backend.copyCountsByAccount[Self.headersAccount, default: 0]
        for _ in 0..<10 {
            _ = try await bundle.store.withSyncFailover(serverURLString: url) { transport in
                _ = try await transport.sync(data: Data(), token: "token")
            }
        }

        #expect(backend.copyCountsByAccount[Self.headersAccount, default: 0] - readsAfterFirst == 0)
        #expect(creations.count == 1)
    }

    @Test func savingHeadersRebuildsTransportAndReadsHeadersOnce() async throws {
        let backend = FakeKeychainBackend()
        let creations = SyncCreationCounter()
        let bundle = try await makeBundle(backend: backend, creations: creations)
        let url = "https://sync.example"
        _ = try await bundle.store.withSyncFailover(serverURLString: url) { transport in
            _ = try await transport.sync(data: Data(), token: "token")
        }

        let configuration = CustomHTTPHeaderConfiguration(
            primary: try EndpointCustomHTTPHeaders(
                url: URL(string: url)!, headers: [.init(name: "X-Test", value: "secret")]
            )
        )
        try bundle.store.saveCustomHTTPHeaders(configuration)
        let readsBefore = backend.copyCountsByAccount[Self.headersAccount, default: 0]
        for _ in 0..<3 {
            _ = try await bundle.store.withSyncFailover(serverURLString: url) { transport in
                _ = try await transport.sync(data: Data(), token: "token")
            }
        }

        #expect(creations.count == 2)
        #expect(backend.copyCountsByAccount[Self.headersAccount, default: 0] - readsBefore == 1)
    }

    @Test func pullWithPendingMessagesReadsTokenOnceAndNoHeaders() async throws {
        let backend = FakeKeychainBackend()
        let creations = SyncCreationCounter()
        let bundle = try await makeBundle(backend: backend, creations: creations)
        let url = "https://sync.example"
        let database = try #require(bundle.store.database)
        var builder = LocalFirstSyncMessageBuilder()
        let draft = try builder.makeMessage(
            dataset: "accounts", row: "bulk-0", column: "name", value: .string("Bulk")
        )
        #expect(try await database.commitLocalSyncMessagesAndEnqueue([draft]) == 1)
        // Warm the transport cache so only per-operation reads remain.
        _ = try await bundle.store.withSyncFailover(serverURLString: url) { transport in
            _ = try await transport.sync(data: Data(), token: "token")
        }
        let tokenAccount = bundle.keychain.account
        let tokenBefore = backend.copyCountsByAccount[tokenAccount, default: 0]
        let headersBefore = backend.copyCountsByAccount[Self.headersAccount, default: 0]

        try await bundle.store.pullAndReload(
            budgetID: "group-1", serverURLString: url, performsScheduleAdvancement: false
        )

        #expect(backend.copyCountsByAccount[tokenAccount, default: 0] - tokenBefore == 1)
        #expect(backend.copyCountsByAccount[Self.headersAccount, default: 0] - headersBefore == 0)
    }

    @Test func tenPullsOnCachedTransportReadTokenOncePerPull() async throws {
        let backend = FakeKeychainBackend()
        let creations = SyncCreationCounter()
        let bundle = try await makeBundle(backend: backend, creations: creations)
        let url = "https://sync.example"
        try await bundle.store.pullAndReload(
            budgetID: "group-1", serverURLString: url, performsScheduleAdvancement: false
        )
        let tokenAccount = bundle.keychain.account
        let tokenBefore = backend.copyCountsByAccount[tokenAccount, default: 0]
        let headersBefore = backend.copyCountsByAccount[Self.headersAccount, default: 0]

        for _ in 0..<10 {
            try await bundle.store.pullAndReload(
                budgetID: "group-1", serverURLString: url, performsScheduleAdvancement: false
            )
        }

        #expect(backend.copyCountsByAccount[tokenAccount, default: 0] - tokenBefore == 10)
        #expect(backend.copyCountsByAccount[Self.headersAccount, default: 0] - headersBefore == 0)
    }
}

private final class SyncCreationCounter: Sendable {
    private let storage = Mutex(0)

    var count: Int { storage.withLock { $0 } }

    func next() -> any ActualSyncTransport {
        storage.withLock { $0 += 1 }
        return RecordingSyncTransport()
    }
}
