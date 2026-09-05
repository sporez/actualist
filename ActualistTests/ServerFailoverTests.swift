import Foundation
import Synchronization
import Testing
@testable import Actualist

@MainActor
@Suite("Server Failover")
struct ServerFailoverTests {

    // MARK: - isFailoverEligible

    @Test("Transport codes classified as failover-eligible")
    func failoverEligibleTransportCodes() {
        #expect(LocalFirstActualStore.isFailoverEligible(ActualAPIError.transport(.cannotConnectToHost)))
        #expect(LocalFirstActualStore.isFailoverEligible(ActualAPIError.transport(.cannotFindHost)))
        #expect(LocalFirstActualStore.isFailoverEligible(ActualAPIError.transport(.timedOut)))
        #expect(LocalFirstActualStore.isFailoverEligible(ActualAPIError.transport(.secureConnectionFailed)))
        #expect(LocalFirstActualStore.isFailoverEligible(ActualAPIError.localNetworkDenied))
        #expect(LocalFirstActualStore.isFailoverEligible(ActualAPIError.httpStatus(502)))
        #expect(LocalFirstActualStore.isFailoverEligible(ActualAPIError.httpStatus(503)))
        #expect(LocalFirstActualStore.isFailoverEligible(ActualAPIError.httpStatus(504)))
    }

    @Test("Non-transport errors are not failover-eligible")
    func nonFailoverEligibleErrors() {
        #expect(!LocalFirstActualStore.isFailoverEligible(ActualAPIError.transport(.notConnectedToInternet)))
        #expect(!LocalFirstActualStore.isFailoverEligible(ActualAPIError.transport(.networkConnectionLost)))
        #expect(!LocalFirstActualStore.isFailoverEligible(ActualAPIError.transport(.serverCertificateUntrusted)))
        #expect(!LocalFirstActualStore.isFailoverEligible(ActualAPIError.transport(nil)))
        #expect(!LocalFirstActualStore.isFailoverEligible(ActualAPIError.httpStatus(400)))
        #expect(!LocalFirstActualStore.isFailoverEligible(ActualAPIError.httpStatus(404)))
        #expect(!LocalFirstActualStore.isFailoverEligible(ActualAPIError.httpStatus(500)))
        #expect(!LocalFirstActualStore.isFailoverEligible(ActualAPIError.serverRejected(status: 502, reason: "invalid-response", details: nil)))
        #expect(!LocalFirstActualStore.isFailoverEligible(ActualAPIError.serverRejected(status: 401, reason: "unauthorized", details: nil)))
        #expect(!LocalFirstActualStore.isFailoverEligible(ActualAPIError.decoding))
        #expect(!LocalFirstActualStore.isFailoverEligible(LocalFirstTestSyncError.failed))
    }

    // MARK: - failoverEndpoints

    @Test("No fallback configured returns primary only")
    func noFallbackReturnsPrimaryOnly() {
        let store = LocalFirstActualStore()
        let endpoints = store.failoverEndpoints(for: "https://primary.example.com")
        #expect(endpoints.primary?.absoluteString == "https://primary.example.com")
        #expect(endpoints.fallback == nil)
    }

    @Test("Fallback configured returns both endpoints")
    func fallbackConfiguredReturnsBoth() {
        let store = LocalFirstActualStore()
        store.fallbackServerURLString = "https://fallback.example.com"
        let endpoints = store.failoverEndpoints(for: "https://primary.example.com")
        #expect(endpoints.primary?.absoluteString == "https://primary.example.com")
        #expect(endpoints.fallback?.absoluteString == "https://fallback.example.com")
    }

    @Test("Fallback identical to primary is ignored")
    func fallbackIdenticalToPrimaryIgnored() {
        let store = LocalFirstActualStore()
        store.fallbackServerURLString = "https://primary.example.com"
        let endpoints = store.failoverEndpoints(for: "https://primary.example.com")
        #expect(endpoints.primary?.absoluteString == "https://primary.example.com")
        #expect(endpoints.fallback == nil)
    }

    @Test("Empty fallback string is ignored")
    func emptyFallbackIgnored() {
        let store = LocalFirstActualStore()
        store.fallbackServerURLString = ""
        let endpoints = store.failoverEndpoints(for: "https://primary.example.com")
        #expect(endpoints.primary?.absoluteString == "https://primary.example.com")
        #expect(endpoints.fallback == nil)
    }

    // MARK: - withSyncFailover

    @Test("Sync uses primary when it succeeds, never contacts fallback")
    func syncPrimarySuccessNoFallback() async throws {
        let primary = RecordingSyncTransport()
        let fallback = RecordingSyncTransport()
        let store = LocalFirstActualStore(
            syncTransportFactory: { url in
                (url.absoluteString == "https://primary.example.com" ? primary : fallback) as any ActualSyncTransport
            }
        )
        store.fallbackServerURLString = "https://fallback.example.com"

        _ = try await store.withSyncFailover(serverURLString: "https://primary.example.com") { transport in
            _ = try await transport.sync(data: Data(), token: "token")
        }

        #expect(await primary.messageCounts() == [0])
        #expect(await fallback.messageCounts() == [])
    }

    @Test("Sync fails over to fallback when primary is unreachable")
    func syncFailsOverToFallback() async throws {
        let primary = FailingSyncTransport(error: .transport(.cannotConnectToHost))
        let fallback = RecordingSyncTransport()
        let store = LocalFirstActualStore(
            syncTransportFactory: { url in
                (url.absoluteString == "https://primary.example.com" ? primary : fallback) as any ActualSyncTransport
            }
        )
        store.fallbackServerURLString = "https://fallback.example.com"

        _ = try await store.withSyncFailover(serverURLString: "https://primary.example.com") { transport in
            _ = try await transport.sync(data: Data(), token: "token")
        }

        #expect(await fallback.messageCounts() == [0])
    }

    @Test("Sync does not fail over on server-rejected errors")
    func syncNoFailoverOnServerError() async throws {
        let primary = FailingSyncTransport(error: .serverRejected(status: 500, reason: "internal", details: nil))
        let fallback = RecordingSyncTransport()
        let store = LocalFirstActualStore(
            syncTransportFactory: { url in
                (url.absoluteString == "https://primary.example.com" ? primary : fallback) as any ActualSyncTransport
            }
        )
        store.fallbackServerURLString = "https://fallback.example.com"

        await #expect(throws: ActualAPIError.self) {
            _ = try await store.withSyncFailover(serverURLString: "https://primary.example.com") { transport in
                _ = try await transport.sync(data: Data(), token: "token")
            }
        }
        #expect(await fallback.messageCounts() == [])
    }

    @Test("Sync does not fail over on authentication failure")
    func syncNoFailoverOnAuthFailure() async throws {
        let primary = FailingSyncTransport(error: .serverRejected(status: 401, reason: "unauthorized", details: nil))
        let fallback = RecordingSyncTransport()
        let store = LocalFirstActualStore(
            syncTransportFactory: { url in
                (url.absoluteString == "https://primary.example.com" ? primary : fallback) as any ActualSyncTransport
            }
        )
        store.fallbackServerURLString = "https://fallback.example.com"

        await #expect(throws: ActualAPIError.self) {
            _ = try await store.withSyncFailover(serverURLString: "https://primary.example.com") { transport in
                _ = try await transport.sync(data: Data(), token: "token")
            }
        }
        #expect(await fallback.messageCounts() == [])
    }

    @Test("Sync propagates primary error when no fallback configured")
    func syncNoFallbackPropagatesPrimaryError() async throws {
        let primary = FailingSyncTransport(error: .transport(.cannotConnectToHost))
        let store = LocalFirstActualStore(
            syncTransportFactory: { _ in primary }
        )

        await #expect(throws: ActualAPIError.self) {
            _ = try await store.withSyncFailover(serverURLString: "https://primary.example.com") { transport in
                _ = try await transport.sync(data: Data(), token: "token")
            }
        }
    }

    @Test("Sync fails over when the primary TLS handshake fails")
    func syncFailsOverOnTLSHandshakeFailure() async throws {
        // A reverse proxy (e.g. Caddy) whose matching site block was removed
        // answers the TCP connection but aborts the TLS handshake. No HTTP
        // bytes are exchanged, so retrying through the fallback is safe.
        let primary = FailingSyncTransport(error: .transport(.secureConnectionFailed))
        let fallback = RecordingSyncTransport()
        let store = LocalFirstActualStore(
            syncTransportFactory: { url in
                (url.absoluteString == "https://primary.example.com" ? primary : fallback) as any ActualSyncTransport
            }
        )
        store.fallbackServerURLString = "https://fallback.example.com"

        _ = try await store.withSyncFailover(serverURLString: "https://primary.example.com") { transport in
            _ = try await transport.sync(data: Data(), token: "token")
        }

        #expect(await fallback.messageCounts() == [0])
    }

    @Test("Sync fails over when the primary reverse proxy reports 502")
    func syncFailsOverOnBadGateway() async throws {
        // A 502/503/504 comes from the proxy layer when the Actual server
        // behind it is down; the server produced no response, so the
        // fallback is tried.
        let primary = FailingSyncTransport(error: .httpStatus(502))
        let fallback = RecordingSyncTransport()
        let store = LocalFirstActualStore(
            syncTransportFactory: { url in
                (url.absoluteString == "https://primary.example.com" ? primary : fallback) as any ActualSyncTransport
            }
        )
        store.fallbackServerURLString = "https://fallback.example.com"

        _ = try await store.withSyncFailover(serverURLString: "https://primary.example.com") { transport in
            _ = try await transport.sync(data: Data(), token: "token")
        }

        #expect(await fallback.messageCounts() == [0])
    }

    // MARK: - withConnectionFailover

    @Test("Connection fails over to fallback when primary is unreachable")
    func connectionFailsOverToFallback() async throws {
        let primary = ConfigurableConnectionTransport(error: .transport(.cannotConnectToHost))
        let fallback = StubConnectionTransport(files: [])
        let store = LocalFirstActualStore(
            connectionTransportFactory: { url in
                (url.absoluteString == "https://primary.example.com" ? primary : fallback) as any ActualServerConnectionTransport
            }
        )
        store.fallbackServerURLString = "https://fallback.example.com"

        let response = try await store.withConnectionFailover(serverURLString: "https://primary.example.com") { client in
            try await client.loginMethods()
        }

        #expect(response.availableLoginMethods.first?.authenticationMethod == .password)
    }

    @Test("Connection does not fail over on server errors")
    func connectionNoFailoverOnServerError() async throws {
        let primary = ConfigurableConnectionTransport(error: .serverRejected(status: 500, reason: "internal", details: nil))
        let fallback = StubConnectionTransport(files: [])
        let store = LocalFirstActualStore(
            connectionTransportFactory: { url in
                (url.absoluteString == "https://primary.example.com" ? primary : fallback) as any ActualServerConnectionTransport
            }
        )
        store.fallbackServerURLString = "https://fallback.example.com"

        await #expect(throws: ActualAPIError.self) {
            _ = try await store.withConnectionFailover(serverURLString: "https://primary.example.com") { client in
                try await client.loginMethods()
            }
        }
    }

    @Test("Connection fails over when the primary reverse proxy reports 503")
    func connectionFailsOverOnServiceUnavailable() async throws {
        let primary = ConfigurableConnectionTransport(error: .httpStatus(503))
        let fallback = StubConnectionTransport(files: [])
        let store = LocalFirstActualStore(
            connectionTransportFactory: { url in
                (url.absoluteString == "https://primary.example.com" ? primary : fallback) as any ActualServerConnectionTransport
            }
        )
        store.fallbackServerURLString = "https://fallback.example.com"

        let response = try await store.withConnectionFailover(serverURLString: "https://primary.example.com") { client in
            try await client.loginMethods()
        }

        #expect(response.availableLoginMethods.first?.authenticationMethod == .password)
    }

    // MARK: - Endpoint attribution

    @Test("Primary success stamps primary endpoint")
    func primarySuccessStampsPrimaryEndpoint() async throws {
        let primary = RecordingSyncTransport()
        let fallback = RecordingSyncTransport()
        let store = LocalFirstActualStore(
            syncTransportFactory: { url in
                (url.absoluteString == "https://primary.example.com" ? primary : fallback) as any ActualSyncTransport
            }
        )
        store.fallbackServerURLString = "https://fallback.example.com"

        _ = try await store.withSyncFailover(serverURLString: "https://primary.example.com") { transport in
            _ = try await transport.sync(data: Data(), token: "token")
        }

        #expect(store.lastSyncEndpoint == .primary)
    }

    @Test("Failover stamps fallback endpoint")
    func failoverStampsFallbackEndpoint() async throws {
        let primary = FailingSyncTransport(error: .httpStatus(502))
        let fallback = RecordingSyncTransport()
        let store = LocalFirstActualStore(
            syncTransportFactory: { url in
                (url.absoluteString == "https://primary.example.com" ? primary : fallback) as any ActualSyncTransport
            }
        )
        store.fallbackServerURLString = "https://fallback.example.com"

        _ = try await store.withSyncFailover(serverURLString: "https://primary.example.com") { transport in
            _ = try await transport.sync(data: Data(), token: "token")
        }

        #expect(store.lastSyncEndpoint == .fallback)
    }

    // MARK: - Sticky skip-primary cache

    @Test("After a successful failover the next sync skips the primary")
    func secondSyncSkipsPrimaryWhileCachedDown() async throws {
        let primary = FailingSyncTransport(error: .transport(.cannotConnectToHost))
        let fallback = RecordingSyncTransport()
        let store = makeStickyStore(
            syncTransportFactory: { url in
                (url.absoluteString == "https://primary.example.com" ? primary : fallback)
                    as any ActualSyncTransport
            }
        )

        try await performSync(on: store)
        try await performSync(on: store)

        #expect(await primary.callCount() == 1)
        #expect(await fallback.messageCounts() == [0, 0])
        #expect(store.lastSyncEndpoint == .fallback)
        #expect(store.endpointHealthDisplay.willSkipPrimary)
        #expect(store.endpointHealthDisplay.summaryText == "Skipping primary")
    }

    @Test("Connection failover shares the sync sticky cache")
    func connectionSkipsPrimaryAfterSyncFailover() async throws {
        let syncPrimary = FailingSyncTransport(error: .transport(.cannotConnectToHost))
        let syncFallback = RecordingSyncTransport()
        let connectionPrimary = ConfigurableConnectionTransport(
            error: .transport(.cannotConnectToHost)
        )
        let connectionFallback = StubConnectionTransport(files: [])
        let store = makeStickyStore(
            syncTransportFactory: { url in
                (url.absoluteString == "https://primary.example.com" ? syncPrimary : syncFallback)
                    as any ActualSyncTransport
            },
            connectionTransportFactory: { url in
                (url.absoluteString == "https://primary.example.com"
                    ? connectionPrimary : connectionFallback)
                    as any ActualServerConnectionTransport
            }
        )

        try await performSync(on: store)
        _ = try await store.withConnectionFailover(
            serverURLString: "https://primary.example.com"
        ) { client in
            try await client.loginMethods()
        }

        #expect(await connectionPrimary.recordedMethods().isEmpty)
        #expect(store.lastSyncEndpoint == .fallback)
    }

    @Test("No fallback configured never skips and never caches health")
    func noFallbackNeverSkips() async throws {
        let primary = RecordingSyncTransport()
        let store = makeStickyStore(
            fallbackURL: nil,
            syncTransportFactory: { _ in primary }
        )

        try await performSync(on: store)
        try await performSync(on: store)

        #expect(await primary.messageCounts() == [0, 0])
        #expect(!store.endpointHealthDisplay.willSkipPrimary)
        #expect(store.endpointHealthDisplay.summaryText == "No fallback configured")
    }

    @Test("TTL expiry re-probes primary and success clears sticky")
    func ttlExpiryReprobesPrimaryAndSuccessClearsSticky() async throws {
        let clock = ControllableClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let primary = CountingSyncTransport(
            error: .transport(.cannotConnectToHost),
            failureCount: 1
        )
        let fallback = RecordingSyncTransport()
        let store = makeStickyStore(
            now: { clock.now },
            ttl: 60,
            syncTransportFactory: { url in
                (url.absoluteString == "https://primary.example.com" ? primary : fallback)
                    as any ActualSyncTransport
            }
        )

        try await performSync(on: store)
        #expect(await primary.callCount() == 1)
        #expect(store.endpointHealthDisplay.willSkipPrimary)

        clock.now = clock.now.addingTimeInterval(60)
        try await performSync(on: store)

        #expect(await primary.callCount() == 2)
        #expect(await fallback.messageCounts() == [0])
        #expect(store.lastSyncEndpoint == .primary)
        #expect(!store.endpointHealthDisplay.willSkipPrimary)
        #expect(store.endpointHealthDisplay.pairs.first?.statusText == "Not cached")

        try await performSync(on: store)
        #expect(await primary.callCount() == 3)
        #expect(await fallback.messageCounts() == [0])
    }

    @Test("TTL expiry with primary still down refreshes sticky")
    func ttlExpiryWithPrimaryStillDownUsesFallbackAgain() async throws {
        let clock = ControllableClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let primary = FailingSyncTransport(error: .httpStatus(502))
        let fallback = RecordingSyncTransport()
        let store = makeStickyStore(
            now: { clock.now },
            ttl: 60,
            syncTransportFactory: { url in
                (url.absoluteString == "https://primary.example.com" ? primary : fallback)
                    as any ActualSyncTransport
            }
        )

        try await performSync(on: store)
        clock.now = clock.now.addingTimeInterval(60)
        try await performSync(on: store)

        #expect(await primary.callCount() == 2)
        #expect(await fallback.messageCounts() == [0, 0])
        #expect(store.endpointHealthDisplay.willSkipPrimary)
    }

    @Test("Eligible fallback failure while skipping clears sticky")
    func eligibleFallbackFailureWhileSkippingClearsSticky() async throws {
        let primary = FailingSyncTransport(error: .transport(.cannotConnectToHost))
        let fallback = CountingSyncTransport()
        let store = makeStickyStore(
            syncTransportFactory: { url in
                url.absoluteString == "https://primary.example.com"
                    ? (primary as any ActualSyncTransport)
                    : fallback
            }
        )

        try await performSync(on: store)
        #expect(await primary.callCount() == 1)
        #expect(store.endpointHealthDisplay.willSkipPrimary)

        await fallback.failNext(.transport(.cannotConnectToHost))
        await #expect(throws: ActualAPIError.self) {
            try await performSync(on: store)
        }
        #expect(await primary.callCount() == 1)
        #expect(await fallback.callCount() == 2)
        #expect(!store.endpointHealthDisplay.willSkipPrimary)

        try await performSync(on: store)
        #expect(await primary.callCount() == 2)
    }

    @Test("Non-eligible fallback failure while skipping keeps sticky")
    func nonEligibleFallbackFailureWhileSkippingKeepsSticky() async throws {
        let primary = FailingSyncTransport(error: .transport(.cannotConnectToHost))
        let fallback = CountingSyncTransport(
            error: .httpStatus(401),
            failureCount: .max
        )
        let store = makeStickyStore(
            syncTransportFactory: { url in
                url.absoluteString == "https://primary.example.com"
                    ? (primary as any ActualSyncTransport)
                    : fallback
            }
        )
        store.notePrimaryUnreachable(
            primary: URL(string: "https://primary.example.com")!,
            fallback: URL(string: "https://fallback.example.com")!
        )
        store.openedServerURLString = "https://primary.example.com"

        await #expect(throws: ActualAPIError.self) {
            try await performSync(on: store)
        }
        #expect(await primary.callCount() == 0)
        #expect(store.endpointHealthDisplay.willSkipPrimary)

        await #expect(throws: ActualAPIError.self) {
            try await performSync(on: store)
        }
        #expect(await primary.callCount() == 0)
    }

    @Test("Changing fallback URL probes primary; restoring it can still skip")
    func fallbackURLChangeMissesThenRestoresStickyPair() async throws {
        let primary = FailingSyncTransport(error: .httpStatus(502))
        let firstFallback = RecordingSyncTransport()
        let secondFallback = RecordingSyncTransport()
        let store = makeStickyStore(
            syncTransportFactory: { url in
                switch url.absoluteString {
                case "https://primary.example.com":
                    primary as any ActualSyncTransport
                case "https://fallback.example.com":
                    firstFallback
                default:
                    secondFallback
                }
            }
        )

        try await performSync(on: store)
        #expect(await primary.callCount() == 1)

        store.fallbackServerURLString = "https://other-fallback.example.com"
        try await performSync(on: store)
        #expect(await primary.callCount() == 2)
        #expect(await secondFallback.messageCounts() == [0])
        #expect(store.endpointHealthDisplay.pairs.contains(where: { !$0.isCurrentPair && $0.isDown }))

        store.fallbackServerURLString = "https://fallback.example.com"
        try await performSync(on: store)
        #expect(await primary.callCount() == 2)
        #expect(await firstFallback.messageCounts() == [0, 0])
    }

    @Test("reset() preserves sticky; eraseLocalData() clears it")
    func resetPreservesStickyAndEraseClearsIt() async throws {
        let primary = FailingSyncTransport(error: .transport(.cannotConnectToHost))
        let fallback = RecordingSyncTransport()
        let backend = FakeKeychainBackend()
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString,
            backend: backend
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistStickyErase-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)
        let clock = ControllableClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let store = LocalFirstActualStore(
            keychain: keychain,
            fileManager: fileManager,
            syncTransportFactory: { url in
                (url.absoluteString == "https://primary.example.com" ? primary : fallback)
                    as any ActualSyncTransport
            },
            endpointHealth: ServerEndpointHealth(now: { clock.now }, ttl: 15 * 60)
        )
        store.fallbackServerURLString = "https://fallback.example.com"
        store.openedServerURLString = "https://primary.example.com"

        try await performSync(on: store)
        store.reset()
        store.openedServerURLString = "https://primary.example.com"
        store.fallbackServerURLString = "https://fallback.example.com"

        try await performSync(on: store)
        #expect(await primary.callCount() == 1)
        #expect(store.endpointHealthDisplay.willSkipPrimary)

        try store.eraseLocalData()
        store.fallbackServerURLString = "https://fallback.example.com"
        store.openedServerURLString = "https://primary.example.com"
        #expect(!store.endpointHealthDisplay.willSkipPrimary)
    }

    // MARK: - Transport client reuse

    @Test("Transport clients are reused across syncs so hasConnected persists")
    func transportClientsReusedAcrossSyncs() async throws {
        let creations = TransportCreationCounter()
        let store = LocalFirstActualStore(
            syncTransportFactory: { _ in creations.next() }
        )

        for _ in 0..<3 {
            _ = try await store.withSyncFailover(serverURLString: "https://primary.example.com") { transport in
                _ = try await transport.sync(data: Data(), token: "token")
            }
        }

        #expect(creations.count == 1)
    }

    @Test("Fallback transport is created once and reused")
    func fallbackTransportReusedAcrossSyncs() async throws {
        // Primary always fails (502) so each sync falls over to the fallback.
        // The fallback transport must be created once and reused across syncs.
        let primary = FailingSyncTransport(error: .httpStatus(502))
        let creations = TransportCreationCounter()
        let store = LocalFirstActualStore(
            syncTransportFactory: { url in
                url.absoluteString == "https://primary.example.com"
                    ? (primary as any ActualSyncTransport)
                    : creations.next()
            }
        )
        store.fallbackServerURLString = "https://fallback.example.com"

        for _ in 0..<3 {
            _ = try await store.withSyncFailover(serverURLString: "https://primary.example.com") { transport in
                _ = try await transport.sync(data: Data(), token: "token")
            }
        }

        #expect(creations.count == 1)
    }

    @Test("reset() clears cached transport clients")
    func resetClearsCachedTransports() async throws {
        let creations = TransportCreationCounter()
        let store = LocalFirstActualStore(
            syncTransportFactory: { _ in creations.next() }
        )

        _ = try await store.withSyncFailover(serverURLString: "https://primary.example.com") { transport in
            _ = try await transport.sync(data: Data(), token: "token")
        }
        store.reset()
        _ = try await store.withSyncFailover(serverURLString: "https://primary.example.com") { transport in
            _ = try await transport.sync(data: Data(), token: "token")
        }

        #expect(creations.count == 2)
    }

    private func makeStickyStore(
        fallbackURL: String? = "https://fallback.example.com",
        now: @escaping () -> Date = Date.init,
        ttl: TimeInterval = 15 * 60,
        syncTransportFactory: @escaping @Sendable (URL) -> any ActualSyncTransport = { _ in
            RecordingSyncTransport()
        },
        connectionTransportFactory: @escaping @Sendable (URL) -> any ActualServerConnectionTransport = { _ in
            StubConnectionTransport(files: [])
        }
    ) -> LocalFirstActualStore {
        let store = LocalFirstActualStore(
            syncTransportFactory: syncTransportFactory,
            connectionTransportFactory: connectionTransportFactory,
            endpointHealth: ServerEndpointHealth(now: now, ttl: ttl)
        )
        store.fallbackServerURLString = fallbackURL
        store.openedServerURLString = "https://primary.example.com"
        return store
    }

    private func performSync(on store: LocalFirstActualStore) async throws {
        _ = try await store.withSyncFailover(serverURLString: "https://primary.example.com") { transport in
            _ = try await transport.sync(data: Data(), token: "token")
        }
    }
}

// MARK: - Test Helpers

/// A sync transport that always throws a fixed error, for testing failover
/// triggering without real networking.
private actor FailingSyncTransport: ActualSyncTransport {
    private let error: ActualAPIError
    private var calls = 0

    init(error: ActualAPIError) {
        self.error = error
    }

    func sync(data: Data, token: String) async throws -> Data {
        calls += 1
        throw error
    }

    func callCount() -> Int {
        calls
    }
}

/// Succeeds after `failureCount` failover-eligible (or other) errors.
private actor CountingSyncTransport: ActualSyncTransport {
    private let error: ActualAPIError?
    private var remainingFailures: Int
    private var nextError: ActualAPIError?
    private var calls = 0

    init(error: ActualAPIError? = nil, failureCount: Int = 0) {
        self.error = error
        self.remainingFailures = failureCount
    }

    func sync(data: Data, token: String) async throws -> Data {
        calls += 1
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        if remainingFailures > 0, let error {
            remainingFailures -= 1
            throw error
        }
        return Data()
    }

    func failNext(_ error: ActualAPIError) {
        nextError = error
    }

    func callCount() -> Int {
        calls
    }
}

@MainActor
private final class ControllableClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

/// Counts how many sync transports a factory has produced, so tests can
/// assert that the store memoizes clients per URL (and clears them on reset).
private final class TransportCreationCounter: Sendable {
    private let storage = Mutex(0)

    var count: Int {
        storage.withLock { $0 }
    }

    func next() -> any ActualSyncTransport {
        storage.withLock { $0 += 1 }
        return RecordingSyncTransport()
    }
}
