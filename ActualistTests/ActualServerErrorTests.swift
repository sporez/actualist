import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func invalidPasswordResponseUsesCredentialMessage() async throws {
        let message = await loginErrorMessage(using: InvalidPasswordURLProtocol.self)

        #expect(message == "The server password is incorrect.")
    }

    @Test func categoryMatchingIsExactAndCannotBeTriggeredByAppendedServerText() {
        #expect(ActualServerErrorCategory.classify(reason: "invalid-password", details: nil) == .invalidPassword)
        #expect(ActualServerErrorCategory.classify(reason: "unauthorized", details: "token-not-found") == .sessionExpired)
        #expect(ActualServerErrorCategory.classify(reason: "opaque", details: "token-not-found") == .sessionExpired)
        let conflicting = ActualServerErrorCategory.classify(reason: "invalid-password", details: "token-not-found")
        #expect(conflicting == .sessionExpired)
        #expect(ActualAPIError.serverRejected(status: nil, reason: conflicting).isAuthenticationFailure)
        #expect(!ActualAPIError.serverRejected(status: 502, reason: conflicting).isAuthenticationFailure)
        #expect(ActualAPIError.serverRejected(status: 401, reason: .invalidPassword).isAuthenticationFailure)
        #expect(ActualServerErrorCategory.classify(reason: "invalid-password unlabeled-token-qq7", details: nil) == .unknown)
        #expect(ActualServerErrorCategory.classify(reason: "opaque", details: "token-not-found synthetic-payee-qq7") == .unknown)
        #expect(ActualAPIError.serverRejected(status: 403, reason: .unknown).isAuthenticationFailure)
        #expect(!ActualAPIError.serverRejected(status: 502, reason: .sessionExpired).isAuthenticationFailure)
        let reset = ActualAPIError.syncRejected(status: 400, reason: .fileHasReset).localizedDescription
        #expect(SafeSyncDiagnostic.storedError(reset) == reset)
        let unconfirmed = LocalFirstError.syncUploadNotConfirmed(2).localizedDescription
        #expect(SafeSyncDiagnostic.storedError(unconfirmed) == unconfirmed)
        #expect(SafeSyncDiagnostic.storedError("\(reset) unlabeled-token-qq7") == SafeSyncDiagnostic.previousFailure)
        let generic = SafeSyncDiagnostic.description(for: LocalFirstTestSyncError.failed)
        #expect(generic == SafeSyncDiagnostic.genericFailure)
        #expect(SafeSyncDiagnostic.storedError(generic) == generic)
        #expect(SafeSyncDiagnostic.storedError("\(generic) unlabeled-token-qq7") == SafeSyncDiagnostic.previousFailure)
    }

    @Test func knownStructuredErrorUsesAppOwnedDescription() async throws {
        let message = await loginErrorMessage(using: DetailedErrorURLProtocol.self)

        #expect(message == "Password sign-in is not enabled on this Actual server.")
    }

    @Test func successfulHTTPErrorEnvelopeIsStillSurfaced() async throws {
        let message = await loginErrorMessage(using: SuccessfulErrorURLProtocol.self)

        #expect(message == "The Actual server rejected an HTTP header.")
    }

    @Test func nonJSONErrorFallsBackToHTTPStatus() async throws {
        let message = await loginErrorMessage(using: ProxyErrorURLProtocol.self)

        #expect(message == "The server returned HTTP 502.")
    }

    @Test func structuredUnauthorizedResponseRequiresReauthentication() async throws {
        let error = await loginError(using: StructuredUnauthorizedURLProtocol.self)

        #expect(error?.isAuthenticationFailure == true)
        #expect(
            error?.localizedDescription
                == "Your Actual session is no longer valid. Sign in again to resume syncing."
        )
    }

    @Test func legacyUnauthorizedResponseRequiresReauthentication() async throws {
        let error = await loginError(using: LegacyUnauthorizedURLProtocol.self)

        #expect(error?.isAuthenticationFailure == true)
        #expect(
            error?.localizedDescription
                == "Your Actual session is no longer valid. Sign in again to resume syncing."
        )
    }

    @Test func hostileServerFieldsNeverBecomeErrorPayloads() async throws {
        let protocolClasses: [AnyClass] = [HostileHTTP500URLProtocol.self, HostileHTTP200URLProtocol.self,
                                           HostileGatewayURLProtocol.self]
        for protocolClass in protocolClasses {
            try await checkHostileResponse(protocolClass: protocolClass)
        }
    }

    private func checkHostileResponse(protocolClass: AnyClass) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://sync.example")!
        let configured = try HTTPHeaderFields(endpoint: EndpointCustomHTTPHeaders(
            url: url,
            headers: [.init(name: "Authorization", value: "synthetic-proxy-value")]
        ))
        for headers in [HTTPHeaderFields.empty, configured] {
            let client = ActualServerSyncClient(baseURL: url, customHeaders: headers, session: session)
            do {
                _ = try await client.loginMethods()
                Issue.record("Expected structured server error")
            } catch let error as ActualAPIError {
                guard case .serverRejected(let status, let category) = error else {
                    Issue.record("Expected structured rejection, got \(error)")
                    continue
                }
                #expect(status == (protocolClass == HostileHTTP200URLProtocol.self ? nil
                                   : protocolClass == HostileGatewayURLProtocol.self ? 502 : 500))
                #expect(category == .unknown)
                #expect(!error.isAuthenticationFailure)
                #expect(!LocalFirstActualStore.isFailoverEligible(error))
                let publicText = error.localizedDescription + String(reflecting: error)
                for secret in HostileHTTP500URLProtocol.secrets {
                    #expect(!publicText.contains(secret))
                }
                #expect(error.localizedDescription == ActualServerErrorCategory.unknown.description)
            }
        }
    }

    @Test func hostileDownloadErrorRemovesPartialArtifact() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HostileHTTP500URLProtocol.self]
        let client = ActualServerSyncClient(baseURL: URL(string: "https://sync.example")!,
                                            session: URLSession(configuration: configuration))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try Data("old-partial".utf8).write(to: destination)
        do {
            try await client.downloadUserFile(fileID: "synthetic-file", token: "synthetic-token", to: destination)
            Issue.record("Expected download rejection")
        } catch let error as ActualAPIError {
            #expect(error.localizedDescription == ActualServerErrorCategory.unknown.description)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    private func loginErrorMessage(using protocolClass: AnyClass) async -> String? {
        await loginError(using: protocolClass)?.localizedDescription
    }

    private func loginError(using protocolClass: AnyClass) async -> ActualAPIError? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        let client = ActualServerSyncClient(
            baseURL: URL(string: "https://sync.example")!,
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await client.loginWithPassword(password: "test-password")
            Issue.record("The server error response should fail")
            return nil
        } catch let error as ActualAPIError {
            return error
        } catch {
            Issue.record("Expected an ActualAPIError, got \(type(of: error))")
            return nil
        }
    }
}

private class ActualErrorURLProtocol: URLProtocol {
    class var statusCode: Int { 400 }
    class var responseBody: Data { Data() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class InvalidPasswordURLProtocol: ActualErrorURLProtocol {
    override class var responseBody: Data {
        Data(#"{"status":"error","reason":"invalid-password"}"#.utf8)
    }
}

private final class DetailedErrorURLProtocol: ActualErrorURLProtocol {
    override class var responseBody: Data {
        Data(
            #"{"status":"error","reason":"forbidden","details":"password-auth-not-active"}"#.utf8
        )
    }
}

private final class SuccessfulErrorURLProtocol: ActualErrorURLProtocol {
    override class var statusCode: Int { 200 }
    override class var responseBody: Data {
        Data(#"{"status":"error","reason":"invalid-header"}"#.utf8)
    }
}

private final class ProxyErrorURLProtocol: ActualErrorURLProtocol {
    override class var statusCode: Int { 502 }
    override class var responseBody: Data {
        Data("Bad Gateway".utf8)
    }
}

private final class StructuredUnauthorizedURLProtocol: ActualErrorURLProtocol {
    override class var statusCode: Int { 401 }
    override class var responseBody: Data {
        Data(
            #"{"status":"error","reason":"unauthorized","details":"token-not-found"}"#.utf8
        )
    }
}

private final class LegacyUnauthorizedURLProtocol: ActualErrorURLProtocol {
    override class var statusCode: Int { 401 }
    override class var responseBody: Data { Data() }
}

private class HostileHTTP500URLProtocol: ActualErrorURLProtocol {
    static let secrets = ["unlabeled-token-qq7", "password-qq7", "synthetic-proxy-value",
                          "synthetic-payee-qq7", "synthetic-address-qq7"]
    override class var statusCode: Int { 500 }
    override class var responseBody: Data {
        let body: [String: String] = [
            "status": "error", "reason": "unlabeled-token-qq7 password-qq7",
            "details": "synthetic-proxy-value synthetic-payee-qq7 synthetic-address-qq7\r\ncontrol"
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }
}

private final class HostileHTTP200URLProtocol: HostileHTTP500URLProtocol {
    override class var statusCode: Int { 200 }
}

private final class HostileGatewayURLProtocol: HostileHTTP500URLProtocol {
    override class var statusCode: Int { 502 }
}

/// A transport that fails the first `failuresRemaining` requests with
/// `URLError(errorCode)` (the signature iOS produces while the Local Network
/// permission sheet is pending or denied) and then succeeds. Counts every
/// attempt so tests can assert whether the retry loop ran. The error code is
/// configurable so tests can cover the iOS 26 case where the first socket fails
/// with a code other than `.cannotConnectToHost`.
final class FirstConnectionRetryURLProtocol: URLProtocol {
    /// URLProtocol instances are created off the main actor; tests mutate this
    /// state on one thread before the session starts.
    nonisolated(unsafe) static var cancellationAttempt: Int?
    nonisolated(unsafe) static var failuresRemaining = 0
    nonisolated(unsafe) static var attemptCount = 0
    nonisolated(unsafe) static var errorCode: URLError.Code = .cannotConnectToHost

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.attemptCount += 1
        if Self.attemptCount == Self.cancellationAttempt {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        if Self.failuresRemaining > 0 {
            Self.failuresRemaining -= 1
            client?.urlProtocol(self, didFailWithError: URLError(Self.errorCode))
            return
        }
        let body = Data(#"{"methods":["password"]}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Serialized because the tests share `FirstConnectionRetryURLProtocol`'s static
/// attempt/failure counters; running them in parallel would corrupt those
/// counts. The retry behavior they cover is owned by `ActualServerSyncClient`'s
/// `withFirstConnectionRecovery`.
@Suite(.serialized)
struct FirstConnectionRetryTests {
    @Test func retriesUntilServerIsReachable() async throws {
        FirstConnectionRetryURLProtocol.attemptCount = 0
        FirstConnectionRetryURLProtocol.failuresRemaining = 2

        let client = makeRetryClient()
        let response = try await client.loginMethods()

        #expect(response.methods == ["password"])
        // Two failed attempts plus the successful third.
        #expect(FirstConnectionRetryURLProtocol.attemptCount == 3)
    }

    @Test func reportsLocalNetworkDeniedWhenRetriesExhaust() async throws {
        FirstConnectionRetryURLProtocol.attemptCount = 0
        FirstConnectionRetryURLProtocol.failuresRemaining = 100

        let client = makeRetryClient(delays: [.milliseconds(1), .milliseconds(1)])

        do {
            _ = try await client.loginMethods()
            Issue.record("The exhausted retry loop should have thrown")
        } catch let error as ActualAPIError {
            guard case .localNetworkDenied = error else {
                Issue.record("Expected .localNetworkDenied, got \(error)")
                return
            }
            #expect(error.localizedDescription.contains("Local Network access"))
        } catch {
            Issue.record("Expected an ActualAPIError, got \(type(of: error))")
        }

        // Initial attempt plus the two retries, all of which failed.
        #expect(FirstConnectionRetryURLProtocol.attemptCount == 3)
    }

    @Test func establishedConnectionFailsFastWithoutRetrying() async throws {
        FirstConnectionRetryURLProtocol.attemptCount = 0
        FirstConnectionRetryURLProtocol.failuresRemaining = 0
        FirstConnectionRetryURLProtocol.errorCode = .cannotConnectToHost

        let client = makeRetryClient()
        // First call succeeds and marks the server as connected.
        _ = try await client.loginMethods()
        let attemptsAfterFirstSuccess = FirstConnectionRetryURLProtocol.attemptCount

        // Now simulate the server going away. Because the connection was already
        // established, the retry loop must not engage; the call fails immediately.
        FirstConnectionRetryURLProtocol.failuresRemaining = 5
        do {
            _ = try await client.loginMethods()
            Issue.record("The second call should have failed")
        } catch let error as ActualAPIError {
            guard case .transport(let code) = error, code == .cannotConnectToHost else {
                Issue.record("Expected .transport(.cannotConnectToHost), got \(error)")
                return
            }
        } catch {
            Issue.record("Expected an ActualAPIError, got \(type(of: error))")
        }

        // Exactly one additional attempt: no retry after an established connection.
        #expect(FirstConnectionRetryURLProtocol.attemptCount == attemptsAfterFirstSuccess + 1)
    }

    @Test func retriesOnNonLocalNetworkTransportCodeBeforeFirstSuccess() async throws {
        // iOS 26 has been observed failing the first socket while the Local
        // Network permission sheet is pending with a code other than
        // `.cannotConnectToHost`/`.cannotFindHost`. The retry loop must still
        // engage, because the safety invariant is `!hasConnected` (no bytes
        // reached the server), not the specific error code.
        FirstConnectionRetryURLProtocol.attemptCount = 0
        FirstConnectionRetryURLProtocol.failuresRemaining = 2
        FirstConnectionRetryURLProtocol.errorCode = .secureConnectionFailed

        let client = makeRetryClient()
        let response = try await client.loginMethods()

        #expect(response.methods == ["password"])
        #expect(FirstConnectionRetryURLProtocol.attemptCount == 3)
    }

    @Test(arguments: [1, 2])
    func cancellationStopsFirstConnectionRetries(attempt: Int) async {
        FirstConnectionRetryURLProtocol.attemptCount = 0
        FirstConnectionRetryURLProtocol.failuresRemaining = 100
        FirstConnectionRetryURLProtocol.errorCode = .cannotConnectToHost
        FirstConnectionRetryURLProtocol.cancellationAttempt = attempt
        defer { FirstConnectionRetryURLProtocol.cancellationAttempt = nil }
        let client = makeRetryClient()
        await #expect(throws: CancellationError.self) { _ = try await client.loginMethods() }
        #expect(FirstConnectionRetryURLProtocol.attemptCount == attempt)
    }

    @Test func cancelledDownloadRemovesPartialFileWithoutRetry() async throws {
        FirstConnectionRetryURLProtocol.attemptCount = 0
        FirstConnectionRetryURLProtocol.cancellationAttempt = 1
        defer { FirstConnectionRetryURLProtocol.cancellationAttempt = nil }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("partial".utf8).write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        let client = makeRetryClient()
        await #expect(throws: CancellationError.self) {
            try await client.downloadUserFile(fileID: "fixture", token: "test", to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FirstConnectionRetryURLProtocol.attemptCount == 1)
    }

    @Test func simpleFINTransportsPreserveCancellation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirstConnectionRetryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let url = URL(string: "https://bank.example")!
        FirstConnectionRetryURLProtocol.attemptCount = 0
        FirstConnectionRetryURLProtocol.failuresRemaining = 100
        FirstConnectionRetryURLProtocol.errorCode = .cancelled
        defer { FirstConnectionRetryURLProtocol.errorCode = .cannotConnectToHost }
        let server = ActualServerSimpleFINClient(baseURL: url, session: session)
        await #expect(throws: CancellationError.self) { _ = try await server.simpleFINStatus(token: "test") }
        let bridge = SimpleFINBridgeClient(baseURL: url, username: "test", password: "test", session: session)
        await #expect(throws: CancellationError.self) { _ = try await bridge.remoteAccounts() }
        let setupToken = Data("https://bank.example/claim".utf8).base64EncodedString()
        await #expect(throws: CancellationError.self) { _ = try await SimpleFINBridgeClient.claim(setupToken: setupToken, session: session) }
        #expect(FirstConnectionRetryURLProtocol.attemptCount == 3)
    }

    private func makeRetryClient(
        delays: [Duration] = [.milliseconds(1), .milliseconds(1), .milliseconds(1)]
    ) -> ActualServerSyncClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirstConnectionRetryURLProtocol.self]
        return ActualServerSyncClient(
            baseURL: URL(string: "https://local-network-permission.example")!,
            session: URLSession(configuration: configuration),
            firstConnectionRetryDelays: delays
        )
    }
}
