import Foundation
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
        #expect(LocalFirstActualStore.isFailoverEligible(ActualAPIError.localNetworkDenied))
    }

    @Test("Non-transport errors are not failover-eligible")
    func nonFailoverEligibleErrors() {
        #expect(!LocalFirstActualStore.isFailoverEligible(ActualAPIError.transport(.notConnectedToInternet)))
        #expect(!LocalFirstActualStore.isFailoverEligible(ActualAPIError.transport(.networkConnectionLost)))
        #expect(!LocalFirstActualStore.isFailoverEligible(ActualAPIError.transport(nil)))
        #expect(!LocalFirstActualStore.isFailoverEligible(ActualAPIError.httpStatus(500)))
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

    // MARK: - withConnectionFailover

    @Test("Connection fails over to fallback when primary is unreachable")
    func connectionFailsOverToFallback() async throws {
        let primary = FailingConnectionTransport(error: .transport(.cannotConnectToHost))
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
        let primary = FailingConnectionTransport(error: .serverRejected(status: 500, reason: "internal", details: nil))
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
}

// MARK: - Test Helpers

/// A sync transport that always throws a fixed error, for testing failover
/// triggering without real networking.
private actor FailingSyncTransport: ActualSyncTransport {
    private let error: ActualAPIError

    init(error: ActualAPIError) {
        self.error = error
    }

    func sync(data: Data, token: String) async throws -> Data {
        throw error
    }
}

/// A connection transport that always throws a fixed error, for testing
/// failover triggering without real networking.
private actor FailingConnectionTransport: ActualServerConnectionTransport {
    private let error: ActualAPIError

    init(error: ActualAPIError) {
        self.error = error
    }

    func loginMethods() async throws -> ActualLoginMethodsResponse {
        throw error
    }

    func loginWithPassword(password: String) async throws -> ActualLoginResponse {
        throw error
    }

    func beginOpenIDLogin(
        returnURL: URL,
        firstTimeLoginPassword: String?
    ) async throws -> ActualOpenIDStartResponse {
        throw error
    }

    func listUserFiles(token: String) async throws -> [ActualSyncRemoteFile] {
        throw error
    }

    func userFileInfo(fileID: String, token: String) async throws -> ActualSyncRemoteFile? {
        throw error
    }

    func downloadUserFile(fileID: String, token: String, to destinationURL: URL) async throws {
        throw error
    }

    func userKey(fileID: String, token: String) async throws -> ActualUserKeyResponse {
        throw error
    }
}
