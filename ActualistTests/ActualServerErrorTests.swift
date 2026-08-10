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
