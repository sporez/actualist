import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func invalidPasswordResponseUsesCredentialMessage() async throws {
        let message = await loginErrorMessage(using: InvalidPasswordURLProtocol.self)

        #expect(message == "The server password is incorrect.")
    }

    @Test func unknownStructuredErrorPreservesActualReasonAndDetails() async throws {
        let message = await loginErrorMessage(using: DetailedErrorURLProtocol.self)

        #expect(message == "Actual server error: forbidden (password-auth-not-active).")
    }

    @Test func successfulHTTPErrorEnvelopeIsStillSurfaced() async throws {
        let message = await loginErrorMessage(using: SuccessfulErrorURLProtocol.self)

        #expect(message == "Actual server error: invalid-header.")
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

/// A transport that fails the first `failuresRemaining` requests with
/// `URLError(errorCode)` (the signature iOS produces while the Local Network
/// permission sheet is pending or denied) and then succeeds. Counts every
/// attempt so tests can assert whether the retry loop ran. The error code is
/// configurable so tests can cover the iOS 26 case where the first socket fails
/// with a code other than `.cannotConnectToHost`.
final class FirstConnectionRetryURLProtocol: URLProtocol {
    static var failuresRemaining = 0
    static var attemptCount = 0
    static var errorCode: URLError.Code = .cannotConnectToHost

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.attemptCount += 1
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
