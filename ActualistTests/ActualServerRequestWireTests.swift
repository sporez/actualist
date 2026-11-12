import Foundation
import Testing
@testable import Actualist

/// Characterizes the exact request every Actual server client builds: method,
/// URL, the controlled headers, timeout and body. The token value is replaced
/// by a placeholder in the compared snapshot so a failing assertion never
/// prints it. Each test owns its StubHTTPEndpoint; no server is contacted.
struct ActualServerRequestWireTests {
    private let endpoint = StubHTTPEndpoint()
    private static let token = "test-token-0001"
    private static let custom = "custom-value-0001"
    private static let sentinelBodyAnswer = #"{"status":"ok","data":{"configured":true,"accounts":[]}}"#

    private struct Wire: Equatable {
        var method: String?
        var url: String?
        var timeout: TimeInterval
        var headers: [String: String]
        var body: Data?
    }

    private func baseURL(_ text: String) -> URL { URL(string: text)! }

    private func customHeaders(for url: URL) throws -> HTTPHeaderFields {
        try HTTPHeaderFields(endpoint: EndpointCustomHTTPHeaders(
            url: url,
            headers: [CustomHTTPHeader(name: "X-Proxy-Test", value: Self.custom)]
        ))
    }

    /// Headers the clients control. System-added headers are ignored; the
    /// token value is masked so a mismatch cannot print it.
    private func wire() throws -> Wire {
        let request = try #require(endpoint.lastRequest)
        let controlled: Set<String> = ["accept", "content-type", "x-proxy-test"]
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let key = name.lowercased()
            guard key.hasPrefix("x-actual-") || controlled.contains(key) else { continue }
            headers[key] = key == "x-actual-token" ? (value == Self.token ? "<token>" : "<unexpected>") : value
        }
        return Wire(
            method: request.httpMethod,
            url: request.url?.absoluteString,
            timeout: request.timeoutInterval,
            headers: headers,
            body: endpoint.lastRequestBody
        )
    }

    private func json(_ data: Data?) throws -> NSDictionary {
        let data = try #require(data)
        return try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    // MARK: - ActualServerSyncClient

    @Test(arguments: [
        ("https://sync.example.com", "https://sync.example.com"),
        ("https://sync.example.com/budget/", "https://sync.example.com/budget")
    ])
    func syncClientBuildsEveryRequest(base: String, expectedPrefix: String) async throws {
        endpoint.respond(statusCode: 200, body: Self.sentinelBodyAnswer)
        let url = baseURL(base)
        let client = ActualServerSyncClient(
            baseURL: url,
            customHeaders: try customHeaders(for: url),
            session: endpoint.makeSession(),
            firstConnectionRetryDelays: []
        )
        let proxy = ["x-proxy-test": Self.custom]
        let json = ["accept": "application/json"].merging(proxy) { $1 }

        _ = try? await client.loginMethods()
        var captured = try wire()
        #expect(captured == Wire(method: "GET", url: "\(expectedPrefix)/account/login-methods",
                                 timeout: 30, headers: json, body: nil))

        _ = try? await client.loginWithPassword(password: "pw-0001")
        captured = try wire()
        #expect(captured.method == "POST")
        #expect(captured.url == "\(expectedPrefix)/account/login")
        #expect(captured.timeout == 30)
        #expect(captured.headers == json.merging(["content-type": "application/json"]) { $1 })
        #expect(try self.json(captured.body) == ["loginMethod": "password", "password": "pw-0001"])

        _ = try? await client.beginOpenIDLogin(returnURL: URL(string: "https://app.example.com/cb")!)
        captured = try wire()
        #expect(captured.method == "POST")
        #expect(captured.url == "\(expectedPrefix)/account/login")
        #expect(captured.headers == json.merging(["content-type": "application/json"]) { $1 })
        #expect(try self.json(captured.body) == ["loginMethod": "openid", "returnUrl": "https://app.example.com/cb"])

        _ = try? await client.listUserFiles(token: Self.token)
        captured = try wire()
        #expect(captured == Wire(method: "GET", url: "\(expectedPrefix)/sync/list-user-files", timeout: 30,
                                 headers: json.merging(["x-actual-token": "<token>"]) { $1 }, body: nil))

        _ = try? await client.userFileInfo(fileID: "file-0001", token: Self.token)
        captured = try wire()
        #expect(captured == Wire(method: "GET", url: "\(expectedPrefix)/sync/get-user-file-info", timeout: 30,
                                 headers: json.merging(["x-actual-token": "<token>", "x-actual-file-id": "file-0001"]) { $1 },
                                 body: nil))

        _ = try? await client.userKey(fileID: "file-0001", token: Self.token)
        captured = try wire()
        #expect(captured.method == "POST")
        #expect(captured.url == "\(expectedPrefix)/sync/user-get-key")
        #expect(captured.timeout == 30)
        #expect(captured.headers == json.merging([
            "x-actual-token": "<token>", "x-actual-file-id": "file-0001", "content-type": "application/json"
        ]) { $1 })
        #expect(try self.json(captured.body) == ["fileId": "file-0001"])

        _ = try? await client.sync(data: Data("wire".utf8), token: Self.token)
        captured = try wire()
        #expect(captured == Wire(
            method: "POST", url: "\(expectedPrefix)/sync/sync", timeout: 30,
            headers: proxy.merging([
                "accept": "application/actual-sync", "content-type": "application/actual-sync",
                "x-actual-token": "<token>"
            ]) { $1 },
            body: Data("wire".utf8)
        ))
        let request = try #require(endpoint.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Content-Length") == "4")

        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try? await client.downloadUserFile(fileID: "file-0001", token: Self.token, to: destination)
        captured = try wire()
        #expect(captured == Wire(
            method: "GET", url: "\(expectedPrefix)/sync/download-user-file", timeout: 30,
            headers: proxy.merging([
                "accept": "application/octet-stream", "x-actual-token": "<token>", "x-actual-file-id": "file-0001"
            ]) { $1 },
            body: nil
        ))
    }

    @Test func unauthenticatedSyncRequestsCarryNoTokenOrFileHeader() async throws {
        endpoint.respond(statusCode: 200, body: Self.sentinelBodyAnswer)
        let client = ActualServerSyncClient(
            baseURL: baseURL("https://sync.example.com"),
            session: endpoint.makeSession(),
            firstConnectionRetryDelays: []
        )
        _ = try? await client.loginMethods()
        #expect(try wire().headers == ["accept": "application/json"])
    }

    // MARK: - ActualServerFileRegistrationClient

    @Test func registrationClientBuildsEveryRequest() async throws {
        endpoint.respond(statusCode: 200, body: #"{"status":"ok","groupId":"group-0001"}"#)
        let url = baseURL("https://registration.example.com/prefix")
        let client = ActualServerFileRegistrationClient(
            baseURL: url,
            customHeaders: try customHeaders(for: url),
            session: endpoint.makeSession()
        )
        let proxy = ["x-proxy-test": Self.custom]

        _ = try? await client.uploadUserFile(
            fileID: "file-0001", name: "Budget & Co", groupID: "group-0002",
            encryptMeta: ActualEncryptedMetadata(keyID: "key-0001", algorithm: "aes-256-gcm", iv: "aXY=", authTag: "dGFn"),
            bytes: Data([0x01, 0x02]), token: Self.token
        )
        var captured = try wire()
        let metaHeader = try #require(endpoint.lastRequest?.value(forHTTPHeaderField: "X-ACTUAL-ENCRYPT-META"))
        #expect(try JSONDecoder().decode(ActualEncryptedMetadata.self, from: Data(metaHeader.utf8)).keyID == "key-0001")
        captured.headers["x-actual-encrypt-meta"] = nil
        #expect(captured == Wire(
            method: "POST", url: "https://registration.example.com/prefix/sync/upload-user-file", timeout: 30,
            headers: proxy.merging([
                "content-type": "application/encrypted-file", "x-actual-token": "<token>",
                "x-actual-file-id": "file-0001", "x-actual-name": "Budget%20%26%20Co",
                "x-actual-format": "2", "x-actual-group-id": "group-0002"
            ]) { $1 },
            body: Data([0x01, 0x02])
        ))

        _ = try? await client.uploadUserFile(
            fileID: "file-0001", name: "B", groupID: nil, encryptMeta: nil,
            bytes: Data([0x03]), token: Self.token
        )
        captured = try wire()
        #expect(captured.headers == proxy.merging([
            "content-type": "application/encrypted-file", "x-actual-token": "<token>",
            "x-actual-file-id": "file-0001", "x-actual-name": "B", "x-actual-format": "2"
        ]) { $1 })

        _ = try? await client.createUserKey(
            fileID: "file-0001", keyID: "key-0001", keySalt: "salt", testContent: "content", token: Self.token
        )
        captured = try wire()
        #expect(captured.method == "POST")
        #expect(captured.url == "https://registration.example.com/prefix/sync/user-create-key")
        #expect(captured.timeout == 30)
        #expect(captured.headers == proxy.merging(["content-type": "application/json", "x-actual-token": "<token>"]) { $1 })
        #expect(try self.json(captured.body) == [
            "fileId": "file-0001", "keyId": "key-0001", "keySalt": "salt", "testContent": "content"
        ])

        _ = try? await client.deleteUserFile(fileID: "file-0001", token: Self.token)
        captured = try wire()
        #expect(captured.method == "POST")
        #expect(captured.url == "https://registration.example.com/prefix/sync/delete-user-file")
        #expect(captured.timeout == 30)
        #expect(captured.headers == proxy.merging(["content-type": "application/json", "x-actual-token": "<token>"]) { $1 })
        #expect(try self.json(captured.body) == ["fileId": "file-0001"])
    }

    // MARK: - ActualServerSimpleFINClient

    @Test func simpleFINClientBuildsEveryRequest() async throws {
        endpoint.respond(statusCode: 200, body: Self.sentinelBodyAnswer)
        let url = baseURL("https://bank.example.com/prefix")
        let client = ActualServerSimpleFINClient(
            baseURL: url,
            customHeaders: try customHeaders(for: url),
            session: endpoint.makeSession()
        )
        let headers = [
            "x-proxy-test": Self.custom, "accept": "application/json", "content-type": "application/json",
            "x-actual-token": "<token>", "x-actual-file-id": "file-0001"
        ]

        _ = try? await client.simpleFINStatus(fileID: "file-0001", token: Self.token)
        var captured = try wire()
        #expect(captured.method == "POST")
        #expect(captured.url == "https://bank.example.com/prefix/simplefin/status")
        #expect(captured.timeout == 60)
        #expect(captured.headers == headers)
        #expect(try self.json(captured.body) == [:])

        _ = try? await client.simpleFINAccounts(fileID: "file-0001", token: Self.token)
        captured = try wire()
        #expect(captured.method == "POST")
        #expect(captured.url == "https://bank.example.com/prefix/simplefin/accounts")
        #expect(captured.timeout == 60)
        #expect(captured.headers == headers)
        #expect(try self.json(captured.body) == [:])

        _ = try? await client.simpleFINTransactions(
            fileID: "file-0001", token: Self.token, accountIDs: ["acct-1"], startDates: ["2026-01-01"]
        )
        captured = try wire()
        #expect(captured.method == "POST")
        #expect(captured.url == "https://bank.example.com/prefix/simplefin/transactions")
        #expect(captured.timeout == 60)
        #expect(captured.headers == headers)
        #expect(try self.json(captured.body) == ["accountId": ["acct-1"], "startDate": ["2026-01-01"]])
    }

    // MARK: - Builder

    @Test func builderJoinsPathKeepsBaseQueryAndWritesTokenOnlyWhenGiven() throws {
        let url = baseURL("https://sync.example.com/prefix/?existing=1")
        let builder = ActualServerRequestBuilder(baseURL: url, customHeaders: try customHeaders(for: url))

        let anonymous = try builder.makeRequest(path: "/a/b", method: "PUT", timeout: 7)
        #expect(anonymous.url?.absoluteString == "https://sync.example.com/prefix/a/b?existing=1")
        #expect(anonymous.httpMethod == "PUT")
        #expect(anonymous.timeoutInterval == 7)
        #expect(anonymous.value(forHTTPHeaderField: "X-ACTUAL-TOKEN") == nil)
        #expect(anonymous.value(forHTTPHeaderField: "X-ACTUAL-FILE-ID") == nil)
        #expect(anonymous.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(anonymous.httpBody == nil)
        #expect(anonymous.value(forHTTPHeaderField: "X-Proxy-Test") == Self.custom)

        let authenticated = try builder.makeRequest(
            path: "a", method: "POST", token: Self.token, fileID: "file-0001",
            headers: ["X-Proxy-Test": "overridden"], timeout: 30, body: Data([1]), contentType: "text/plain"
        )
        #expect(authenticated.value(forHTTPHeaderField: "X-ACTUAL-TOKEN") == Self.token)
        #expect(authenticated.value(forHTTPHeaderField: "X-ACTUAL-FILE-ID") == "file-0001")
        #expect(authenticated.value(forHTTPHeaderField: "X-Proxy-Test") == "overridden")
        #expect(authenticated.value(forHTTPHeaderField: "Content-Type") == "text/plain")
        #expect(authenticated.httpBody == Data([1]))
    }

    // MARK: - URL validation

    @Test func everyClientRefusesAnUnsupportedBaseURLBeforeSending() async throws {
        let url = baseURL("ftp://sync.example.com")
        let session = endpoint.makeSession()
        let sync = ActualServerSyncClient(baseURL: url, session: session, firstConnectionRetryDelays: [])
        let registration = ActualServerFileRegistrationClient(baseURL: url, session: session)
        let simpleFIN = ActualServerSimpleFINClient(baseURL: url, session: session)

        await expectInvalidURL { _ = try await sync.listUserFiles(token: Self.token) }
        await expectInvalidURL {
            try await sync.downloadUserFile(
                fileID: "file-0001", token: Self.token,
                to: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            )
        }
        await expectInvalidURL { try await registration.deleteUserFile(fileID: "file-0001", token: Self.token) }
        await expectInvalidURL { _ = try await simpleFIN.simpleFINStatus(fileID: "file-0001", token: Self.token) }
        #expect(endpoint.lastRequest == nil)
    }

    private func expectInvalidURL(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected an invalid URL error")
        } catch ActualAPIError.invalidURL {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
