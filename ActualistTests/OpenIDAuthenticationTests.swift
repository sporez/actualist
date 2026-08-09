import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func loginMethodsDecodeMetadataAndUnknownMethodsLossily() throws {
        let response = try JSONDecoder.actual.decode(
            ActualLoginMethodsResponse.self,
            from: Data("""
            {
              "methods": [
                "password",
                { "method": "openid", "active": 1, "displayName": "Company SSO" },
                { "method": "header", "active": 0, "displayName": "Proxy" },
                { "method": "future-auth", "active": true },
                { "active": true },
                42
              ]
            }
            """.utf8)
        )

        #expect(response.methods == ["password", "openid", "future-auth"])
        #expect(response.loginMethods.count == 4)
        #expect(response.loginMethods[1].displayName == "Company SSO")
        #expect(response.loginMethods[1].authenticationMethod == .openID)
        #expect(response.loginMethods[2].authenticationMethod == .header)
        #expect(response.loginMethods[3].authenticationMethod == .unsupported("future-auth"))
    }

    @Test func openIDStartResponseDecodesActualDataShape() throws {
        let response = try JSONDecoder.actual.decode(
            ActualOpenIDStartResponse.self,
            from: Data(#"{"status":"ok","data":{"returnUrl":"https://id.example/authorize"}}"#.utf8)
        )
        #expect(response.returnURL == URL(string: "https://id.example/authorize"))
    }

    @Test func openIDCallbackParserAcceptsOnlyTheExpectedAttempt() throws {
        let nonce = "abc123"
        let valid = try #require(
            URL(string: "com.sporez.actualist://localhost/openid/abc123/openid-cb?other=1&token=session%2Btoken")
        )
        #expect(try ActualOpenIDCallbackParser.token(from: valid, expectedNonce: nonce) == "session+token")

        let wrongScheme = try #require(URL(string: "other://localhost/openid/abc123/openid-cb?token=x"))
        #expect(throws: ActualOpenIDAuthenticationError.invalidCallback) {
            try ActualOpenIDCallbackParser.token(from: wrongScheme, expectedNonce: nonce)
        }
        let wrongHost = try #require(URL(string: "com.sporez.actualist://other/openid/abc123/openid-cb?token=x"))
        #expect(throws: ActualOpenIDAuthenticationError.invalidCallback) {
            try ActualOpenIDCallbackParser.token(from: wrongHost, expectedNonce: nonce)
        }
        let stale = try #require(URL(string: "com.sporez.actualist://localhost/openid/old/openid-cb?token=x"))
        #expect(throws: ActualOpenIDAuthenticationError.invalidCallback) {
            try ActualOpenIDCallbackParser.token(from: stale, expectedNonce: nonce)
        }
        let missing = try #require(URL(string: "com.sporez.actualist://localhost/openid/abc123/openid-cb"))
        #expect(throws: ActualOpenIDAuthenticationError.missingToken) {
            try ActualOpenIDCallbackParser.token(from: missing, expectedNonce: nonce)
        }
        let duplicate = try #require(
            URL(string: "com.sporez.actualist://localhost/openid/abc123/openid-cb?token=a&token=b")
        )
        #expect(throws: ActualOpenIDAuthenticationError.ambiguousToken) {
            try ActualOpenIDCallbackParser.token(from: duplicate, expectedNonce: nonce)
        }
    }

    @Test func openIDCoordinatorCorrelatesCallbackAndReturnsActualToken() async throws {
        let transport = StubConnectionTransport(
            loginMethodsData: Data(#"{"methods":["openid"]}"#.utf8)
        )
        let coordinator = ActualOpenIDAuthenticationCoordinator()

        let token = try await coordinator.authenticate(client: transport) { authorizationURL in
            #expect(authorizationURL == URL(string: "https://identity.example/authorize"))
            var callback = try #require(await transport.capturedOpenIDReturnURL)
            callback.append(path: "openid-cb")
            callback.append(queryItems: [URLQueryItem(name: "token", value: "actual-token")])
            return callback
        }

        #expect(token == "actual-token")
        let returnURL = try #require(await transport.capturedOpenIDReturnURL)
        #expect(returnURL.scheme == ActualOpenIDAuthenticationCoordinator.callbackScheme)
        #expect(returnURL.host == "localhost")
        #expect(returnURL.pathComponents.count == 3)
        #expect(await transport.capturedFirstTimeLoginPassword == nil)
    }

    @Test func authenticatedStagingUsesTheProvidedTokenWithoutCommittingIt() async throws {
        let file = ActualSyncRemoteFile(
            fileID: "file-1",
            groupID: "group-1",
            name: "Budget",
            deleted: false,
            encryptKeyID: nil,
            requiresEncryptionPassword: false
        )
        let transport = StubConnectionTransport(files: [file])
        let keychain = KeychainStore(service: "OpenIDTests", account: UUID().uuidString)
        let store = LocalFirstActualStore(
            keychain: keychain,
            connectionTransportFactory: { _ in transport }
        )

        let staged = try await store.stageAuthenticatedConnection(
            serverURLString: "https://sync.example",
            token: "openid-token",
            selectedBudgetID: "group-1"
        )

        #expect(staged.token == "openid-token")
        #expect(staged.budgets.map(\.syncID) == ["group-1"])
        #expect(keychain.readActualSyncToken().isEmpty)
    }

    @Test func onboardingStatePrefersOpenIDWhenBothMethodsAreAvailable() throws {
        let response = try JSONDecoder.actual.decode(
            ActualLoginMethodsResponse.self,
            from: Data(#"{"methods":["password","openid"]}"#.utf8)
        )
        let viewModel = OnboardingViewModel()
        viewModel.loginMethods = response.activeLoginMethods
        viewModel.hasLoadedLoginMethods = true
        viewModel.isUsingPassword = viewModel.supportsPassword && !viewModel.supportsOpenID

        #expect(viewModel.supportsOpenID)
        #expect(viewModel.supportsPassword)
        #expect(!viewModel.showsPasswordForm)
        #expect(viewModel.unsupportedAuthenticationMessage == nil)
    }

    @Test func onboardingStateExplainsHeaderAuthentication() throws {
        let response = try JSONDecoder.actual.decode(
            ActualLoginMethodsResponse.self,
            from: Data(#"{"methods":[{"method":"header","active":1}]}"#.utf8)
        )
        let viewModel = OnboardingViewModel()
        viewModel.loginMethods = response.activeLoginMethods
        viewModel.hasLoadedLoginMethods = true

        #expect(viewModel.unsupportedAuthenticationMessage?.contains("header authentication") == true)
    }

    @Test func openIDTransportSendsActualManagedLoginPayload() async throws {
        OpenIDRequestURLProtocol.capturedRequest = nil
        OpenIDRequestURLProtocol.capturedBody = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenIDRequestURLProtocol.self]
        let client = ActualServerSyncClient(
            baseURL: try #require(URL(string: "https://sync.example")),
            session: URLSession(configuration: configuration)
        )
        let returnURL = try #require(URL(string: "com.sporez.actualist://localhost/openid/nonce"))

        _ = try await client.beginOpenIDLogin(
            returnURL: returnURL,
            firstTimeLoginPassword: nil
        )

        let request = try #require(OpenIDRequestURLProtocol.capturedRequest)
        let body = try #require(OpenIDRequestURLProtocol.capturedBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(request.url?.path == "/account/login")
        #expect(payload["loginMethod"] == "openid")
        #expect(payload["returnUrl"] == returnURL.absoluteString)
        #expect(payload["password"] == nil)
    }
}

final class OpenIDRequestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequest = request
        Self.capturedBody = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        let body = Data(#"{"status":"ok","data":{"returnUrl":"https://identity.example/authorize"}}"#.utf8)
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

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
