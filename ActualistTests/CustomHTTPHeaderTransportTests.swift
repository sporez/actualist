import Foundation
import Testing
@testable import Actualist

@Suite(.serialized)
struct CustomHTTPHeaderTransportTests {
    func session() -> URLSession {
        HeaderTransportURLProtocol.requests = []
        HeaderTransportURLProtocol.mode = .normal
        let configuration = ActualServerSyncClient.secureSessionConfiguration()
        configuration.protocolClasses = [HeaderTransportURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func configuration() throws -> CustomHTTPHeaderConfiguration {
        .init(
            primary: try EndpointCustomHTTPHeaders(url: URL(string: "https://primary.example")!, headers: [.init(name: "X-Primary", value: "primary-secret")]),
            fallback: try EndpointCustomHTTPHeaders(url: URL(string: "https://fallback.example")!, headers: [.init(name: "X-Fallback", value: "fallback-secret")])
        )
    }

    @Test func everyActualRequestFamilyAndBridgeIsolation() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://primary.example")!
        let fields = try configuration().fields(for: .primary, url: url)
        let client = ActualServerSyncClient(baseURL: url, customHeaders: fields, session: session)
        _ = try await client.loginMethods()
        _ = try await client.loginWithPassword(password: "password")
        _ = try await client.beginOpenIDLogin(returnURL: URL(string: "com.sporez.actualist://localhost/test")!)
        _ = try await client.listUserFiles(token: "actual-token")
        _ = try await client.userFileInfo(fileID: "file", token: "actual-token")
        _ = try await client.userKey(fileID: "file", token: "actual-token")
        _ = try await client.sync(data: Data("wire".utf8), token: "actual-token")
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try await client.downloadUserFile(fileID: "file", token: "actual-token", to: destination)
        let bank = ActualServerSimpleFINClient(baseURL: url, customHeaders: fields, session: session)
        _ = try await bank.simpleFINStatus(token: "actual-token")
        _ = try await bank.simpleFINAccounts(token: "actual-token")
        _ = try await bank.simpleFINTransactions(token: "actual-token", accountIDs: ["a"], startDates: ["2026-01-01"])
        #expect(HeaderTransportURLProtocol.requests.count == 11)
        for request in HeaderTransportURLProtocol.requests {
            #expect(request.value(forHTTPHeaderField: "X-Primary") == "primary-secret")
            #expect(request.value(forHTTPHeaderField: "X-Fallback") == nil)
            if request.url!.path.hasPrefix("/sync/") || request.url!.path.hasPrefix("/simplefin/") {
                #expect(request.value(forHTTPHeaderField: "X-ACTUAL-TOKEN") == "actual-token")
            }
            if ["/sync/get-user-file-info", "/sync/download-user-file", "/sync/user-get-key"].contains(request.url!.path) {
                #expect(request.value(forHTTPHeaderField: "X-ACTUAL-FILE-ID") == "file")
            }
            if request.url!.path != "/sync/sync" {
                let expectedAccept = request.url!.path == "/sync/download-user-file" ? "application/octet-stream" : "application/json"
                #expect(request.value(forHTTPHeaderField: "Accept") == expectedAccept)
                if request.httpMethod == "POST" {
                    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                }
            }
            if request.url!.path == "/sync/sync" {
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/actual-sync")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/actual-sync")
                #expect(request.value(forHTTPHeaderField: "Content-Length") == "4")
            }
        }
        let bridge = SimpleFINBridgeClient(baseURL: URL(string: "https://bridge.example")!, username: "user", password: "password", session: session)
        _ = try await bridge.remoteAccounts()
        let request = try #require(HeaderTransportURLProtocol.requests.last)
        #expect(request.value(forHTTPHeaderField: "X-Primary") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Fallback") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
    }

    @Test @MainActor func failoverCacheReplacementAndOriginChanges() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let keychain = KeychainStore(service: UUID().uuidString, account: "token", backend: FakeKeychainBackend())
        let store = LocalFirstActualStore(keychain: keychain, transportSession: session)
        store.fallbackServerURLString = "https://fallback.example"
        try store.saveCustomHTTPHeaders(configuration())
        HeaderTransportURLProtocol.mode = .failPrimary
        _ = try await store.loginMethods(serverURLString: "https://primary.example")
        #expect(HeaderTransportURLProtocol.requests.map { $0.url!.host! } == ["primary.example", "fallback.example"])
        #expect(HeaderTransportURLProtocol.requests[0].value(forHTTPHeaderField: "X-Primary") == "primary-secret")
        #expect(HeaderTransportURLProtocol.requests[0].value(forHTTPHeaderField: "X-Fallback") == nil)
        #expect(HeaderTransportURLProtocol.requests[1].value(forHTTPHeaderField: "X-Fallback") == "fallback-secret")
        #expect(HeaderTransportURLProtocol.requests[1].value(forHTTPHeaderField: "X-Primary") == nil)
        HeaderTransportURLProtocol.mode = .normal
        let url = URL(string: "https://primary.example")!
        _ = try await store.syncTransport(for: url).sync(data: Data(), token: "token")
        _ = try await store.simpleFINTransport(for: url).simpleFINStatus(token: "token")
        var updated = try configuration()
        updated.primary = try EndpointCustomHTTPHeaders(url: url, headers: [.init(name: "X-Primary", value: "replacement-secret")])
        store.openedBudgetID = "preserved-budget"
        try store.saveCustomHTTPHeaders(updated)
        #expect(store.openedBudgetID == "preserved-budget")
        _ = try await store.connectionTransport(for: url).loginMethods()
        _ = try await store.syncTransport(for: url).sync(data: Data(), token: "token")
        _ = try await store.simpleFINTransport(for: url).simpleFINStatus(token: "token")
        #expect(HeaderTransportURLProtocol.requests.suffix(3).allSatisfy { $0.value(forHTTPHeaderField: "X-Primary") == "replacement-secret" })
        _ = try await store.connectionTransport(for: URL(string: "https://changed.example")!).loginMethods()
        #expect(HeaderTransportURLProtocol.requests.last?.value(forHTTPHeaderField: "X-Primary") == nil)
        let freshBackgroundStore = LocalFirstActualStore(keychain: keychain, transportSession: session)
        _ = try await freshBackgroundStore.connectionTransport(for: url).loginMethods()
        #expect(HeaderTransportURLProtocol.requests.last?.value(forHTTPHeaderField: "X-Primary") == "replacement-secret")
    }

    @Test @MainActor func binaryAndBankTransportsFollowFallbackRole() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let keychain = KeychainStore(service: UUID().uuidString, account: "token", backend: FakeKeychainBackend())
        try keychain.saveActualSyncToken("actual-token")
        let store = LocalFirstActualStore(keychain: keychain, transportSession: session)
        try store.saveCustomHTTPHeaders(configuration())
        store.fallbackServerURLString = "https://fallback.example"
        store.openedServerURLString = "https://primary.example"
        store.openedBudgetID = "group-1"
        store.database = try BudgetDatabase(databaseURL: LocalFirstActualStoreTests().makeSQLiteFixture())
        HeaderTransportURLProtocol.mode = .failPrimary
        _ = try await store.withSyncFailover(serverURLString: "https://primary.example") { transport in
            try await transport.sync(data: Data(), token: "actual-token")
        }
        _ = try await store.bankSyncSupport(budgetID: "group-1")
        #expect(HeaderTransportURLProtocol.requests.count == 3)
        #expect(HeaderTransportURLProtocol.requests.suffix(2).allSatisfy {
            $0.value(forHTTPHeaderField: "X-Fallback") == "fallback-secret"
                && $0.value(forHTTPHeaderField: "X-Primary") == nil
        })
    }

    @Test func verificationAndSanitizedError() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let verifier = CustomHTTPHeaderVerifier(session: session)
        let url = URL(string: "https://primary.example")!
        let headers = [CustomHTTPHeader(name: "X-Primary", value: "primary-secret")]
        #expect(try await verifier.verify(url: url, headers: headers) == .acceptsWithAndWithoutHeaders)
        let countBeforeEmptyTest = HeaderTransportURLProtocol.requests.count
        #expect(try await verifier.verify(url: url, headers: []) == .noHeaders)
        #expect(HeaderTransportURLProtocol.requests.count == countBeforeEmptyTest + 1)
        HeaderTransportURLProtocol.mode = .requireHeaders
        #expect(try await verifier.verify(url: url, headers: headers) == .comparisonFailed)
        HeaderTransportURLProtocol.mode = .echoFailure
        do {
            _ = try await verifier.verify(url: url, headers: headers)
            Issue.record("Expected failure")
        } catch {
            #expect(!error.localizedDescription.contains("primary-secret"))
        }
        HeaderTransportURLProtocol.mode = .echoBankFailure
        let bank = ActualServerSimpleFINClient(
            baseURL: url,
            customHeaders: try HTTPHeaderFields(endpoint: EndpointCustomHTTPHeaders(url: url, headers: headers)),
            session: session
        )
        do {
            _ = try await bank.simpleFINTransactions(token: "token", accountIDs: ["a"], startDates: ["2026-01-01"])
            Issue.record("Expected secret-bearing bank error to be rejected")
        } catch ActualAPIError.invalidResponse {
            // The raw error metadata must never reach the caller.
        }
        let count = HeaderTransportURLProtocol.requests.count
        await #expect(throws: CustomHTTPHeaderError.invalidValue) {
            try await verifier.verify(url: url, headers: [.init(name: "X-Test", value: "bad\r\nsecret")])
        }
        #expect(HeaderTransportURLProtocol.requests.count == count)
    }
}

final class HeaderTransportURLProtocol: URLProtocol {
    enum Mode { case normal, failPrimary, requireHeaders, echoFailure, crossOriginOIDC, echoBankFailure }
    nonisolated(unsafe) static var callbackURL: URL?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var mode = Mode.normal
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = payload["returnUrl"] as? String { Self.callbackURL = URL(string: value) }
        }
        if let data = request.httpBody,
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = payload["returnUrl"] as? String { Self.callbackURL = URL(string: value) }
        let path = request.url!.path
        var status = 200
        var body = #"{"methods":["password","openid"]}"#
        switch path {
        case "/account/login": body = #"{"status":"ok","data":{"token":"token","returnUrl":"https://primary.example/openid"}}"#
        case "/sync/list-user-files": body = #"{"files":[]}"#
        case "/sync/get-user-file-info": body = #"{"file":null}"#
        case "/sync/user-get-key": body = #"{"id":"key","salt":"salt"}"#
        case "/sync/download-user-file": body = "archive"
        case "/simplefin/status": body = #"{"configured":true}"#
        case "/simplefin/accounts": body = #"{"data":{"accounts":[]}}"#
        case "/simplefin/transactions": body = #"{"data":{}}"#
        case "/accounts": body = #"{"accounts":[]}"#
        default: break
        }
        if Self.mode == .crossOriginOIDC {
            body = #"{"status":"ok","data":{"returnUrl":"https://identity.example/authorize"}}"#
        }
        if Self.mode == .failPrimary && request.url!.host == "primary.example" { status = 503 }
        if Self.mode == .requireHeaders && request.value(forHTTPHeaderField: "X-Primary") == nil { status = 403 }
        if Self.mode == .echoFailure {
            status = 400
            body = #"{"status":"error","reason":"primary-secret","details":"primary-secret"}"#
        }
        if Self.mode == .echoBankFailure {
            body = #"{"data":{"a":{"error_code":"primary-secret"}}}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
