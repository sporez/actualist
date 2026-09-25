import Foundation
import Network
import Synchronization
import Testing
@testable import Actualist

@Suite(.serialized)
struct CustomHTTPHeaderRedirectTests {
    @Test(arguments: [301, 302, 303, 307, 308], [false, true])
    func bodylessRedirectsRespectEndpointOrigin(status: Int, headers: Bool) async throws {
        let receiver = try HeaderRedirectTestServer { _ in Self.response(body: #"{"methods":["password"]}"#) }
        try await receiver.start()
        defer { receiver.stop() }
        let origin = try HeaderRedirectTestServer { request in
            if request.contains(" /final ") { return Self.response(body: #"{"methods":["password"]}"#) }
            let target = request.contains(" /cross/") ? receiver.url.absoluteString : "/final"
            return Self.redirect(status: status, location: target)
        }
        try await origin.start()
        defer { origin.stop() }
        let fields = try Self.fields(origin.url, configured: headers)
        let same = ActualServerSyncClient(baseURL: origin.url.appending(path: "same"), customHeaders: fields, firstConnectionRetryDelays: [])
        let cross = ActualServerSyncClient(baseURL: origin.url.appending(path: "cross"), customHeaders: fields, firstConnectionRetryDelays: [])
        _ = try await same.loginMethods()
        await Self.expectRefusal { try await cross.loginMethods() }
        #expect(receiver.requests.isEmpty)
        let final = origin.requests.filter { $0.contains(" /final ") }
        #expect(final.count == 1)
        #expect(final[0].contains("GET /final "))
        if headers {
            #expect(final[0].lowercased().contains("authorization: bearer proxy-secret"))
            #expect(final[0].lowercased().contains("x-proxy-credential: proxy-secret"))
        }
    }

    @Test(arguments: [301, 302, 303, 307, 308], [false, true])
    func payloadsAndStreamedDownloadsNeverReachOtherServer(status: Int, headers: Bool) async throws {
        let receiver = try HeaderRedirectTestServer { _ in Self.response(body: "unexpected") }
        try await receiver.start()
        defer { receiver.stop() }
        let origin = try HeaderRedirectTestServer { _ in
            Self.redirect(status: status, location: receiver.url.absoluteString)
        }
        try await origin.start()
        defer { origin.stop() }
        let fields = try Self.fields(origin.url, configured: headers)
        let client = ActualServerSyncClient(baseURL: origin.url, customHeaders: fields, firstConnectionRetryDelays: [])
        await Self.expectRefusal { try await client.loginWithPassword(password: "login-sentinel") }
        await Self.expectRefusal {
            try await client.beginOpenIDLogin(
                returnURL: URL(string: "com.sporez.actualist://localhost/openid")!,
                firstTimeLoginPassword: "openid-sentinel"
            )
        }
        await Self.expectRefusal { try await client.userKey(fileID: "file-sentinel", token: "token-sentinel") }
        await Self.expectRefusal { try await client.sync(data: Data("sync-sentinel".utf8), token: "token-sentinel") }
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        await Self.expectRefusal {
            try await client.downloadUserFile(fileID: "file-sentinel", token: "token-sentinel", to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let bank = ActualServerSimpleFINClient(baseURL: origin.url, customHeaders: fields)
        await Self.expectRefusal { try await bank.simpleFINStatus(token: "token-sentinel") }
        await Self.expectRefusal { try await bank.simpleFINTransactions(token: "token-sentinel", accountIDs: ["bank-sentinel"], startDates: ["2026-01-01"]) }
        #expect(receiver.requests.isEmpty)
        #expect(origin.requests.count == 7)
        #expect(origin.requests.contains { $0.contains("login-sentinel") })
        #expect(origin.requests.contains { $0.contains("openid-sentinel") })
        #expect(origin.requests.contains { $0.contains("sync-sentinel") })
        #expect(origin.requests.contains { $0.contains("bank-sentinel") })
        let actualTokenRequests = origin.requests.filter { $0.contains(" /sync/") || $0.contains(" /simplefin/") }
        #expect(actualTokenRequests.count == 5)
        #expect(actualTokenRequests.allSatisfy { $0.lowercased().contains("x-actual-token: token-sentinel") })
        #expect(origin.requests.filter { $0.contains("/sync/user-get-key") || $0.contains("/sync/download-user-file") }
            .allSatisfy { $0.lowercased().contains("x-actual-file-id: file-sentinel") })
    }

    @Test(arguments: [false, true])
    func sameOriginMultiHopPreservesPostAndActualHeaders(headers: Bool) async throws {
        let origin = try HeaderRedirectTestServer { request in
            if request.contains(" /start/") { return Self.redirect(status: 307, location: "/middle") }
            if request.contains(" /middle ") { return Self.redirect(status: 308, location: "/final") }
            return Self.response(body: "wire-response")
        }
        try await origin.start()
        defer { origin.stop() }
        let client = ActualServerSyncClient(baseURL: origin.url.appending(path: "start"), customHeaders: try Self.fields(origin.url, configured: headers), firstConnectionRetryDelays: [])
        #expect(try await client.sync(data: Data("wire-sentinel".utf8), token: "actual-token") == Data("wire-response".utf8))
        #expect(origin.requests.count == 3)
        for request in origin.requests {
            #expect(request.contains("POST "))
            #expect(request.contains("wire-sentinel"))
            #expect(request.lowercased().contains("x-actual-token: actual-token"))
            #expect(request.lowercased().contains("authorization: bearer proxy-secret") == headers)
            #expect(request.lowercased().contains("x-proxy-credential: proxy-secret") == headers)
        }
    }

    @Test(arguments: [302, 303])
    func sameOriginPostConversionUsesNativeGETWithoutBody(status: Int) async throws {
        let origin = try HeaderRedirectTestServer { request in
            request.contains(" /final ")
                ? Self.response(body: #"{"token":"login-ok"}"#)
                : Self.redirect(status: status, location: "/final")
        }
        try await origin.start()
        defer { origin.stop() }
        let client = ActualServerSyncClient(baseURL: origin.url, firstConnectionRetryDelays: [])

        _ = try await client.loginWithPassword(password: "login-sentinel")

        #expect(origin.requests.count == 2)
        #expect(origin.requests[0].contains("POST /account/login "))
        #expect(origin.requests[0].contains("login-sentinel"))
        #expect(origin.requests[1].contains("GET /final "))
        #expect(!origin.requests[1].contains("login-sentinel"))
        #expect(origin.requests[1].components(separatedBy: "\r\n\r\n").last == "")
    }

    @Test func sameOriginStreamAndSimpleFINKeepHeaders() async throws {
        let origin = try HeaderRedirectTestServer { request in
            if request.contains(" /download-final ") { return Self.response(body: "archive") }
            if request.contains(" /bank-final ") { return Self.response(body: #"{"configured":true}"#) }
            let location = request.contains("/sync/download-user-file") ? "/download-final" : "/bank-final"
            return Self.redirect(status: 307, location: location)
        }
        try await origin.start()
        defer { origin.stop() }
        let baseURL = origin.url.appending(path: "same")
        let fields = try Self.fields(origin.url, configured: true)
        let client = ActualServerSyncClient(baseURL: baseURL, customHeaders: fields, firstConnectionRetryDelays: [])
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try await client.downloadUserFile(fileID: "file", token: "actual-token", to: destination)
        #expect(try Data(contentsOf: destination) == Data("archive".utf8))
        let bank = ActualServerSimpleFINClient(baseURL: baseURL, customHeaders: fields)
        #expect(try await bank.simpleFINStatus(token: "actual-token") == .configured)
        #expect(origin.requests.count == 4)
        let final = origin.requests.filter { $0.contains(" /download-final ") || $0.contains(" /bank-final ") }
        #expect(final.count == 2)
        #expect(final.allSatisfy { $0.lowercased().contains("authorization: bearer proxy-secret") })
        #expect(final.allSatisfy { $0.lowercased().contains("x-actual-token: actual-token") })
    }

    @Test func sameOriginThenCrossOriginStopsBeforeReceiver() async throws {
        let receiver = try HeaderRedirectTestServer { _ in Self.response(body: "unexpected") }
        try await receiver.start()
        defer { receiver.stop() }
        let origin = try HeaderRedirectTestServer { request in
            request.contains(" /final ")
                ? Self.redirect(status: 308, location: receiver.url.absoluteString)
                : Self.redirect(status: 307, location: "/final")
        }
        try await origin.start()
        defer { origin.stop() }
        let client = ActualServerSyncClient(baseURL: origin.url, firstConnectionRetryDelays: [])
        await Self.expectRefusal { try await client.sync(data: Data("wire-sentinel".utf8), token: "actual-token") }
        #expect(origin.requests.count == 2)
        #expect(receiver.requests.isEmpty)
    }

    private static func fields(_ url: URL, configured: Bool) throws -> HTTPHeaderFields {
        guard configured else { return .empty }
        return try HTTPHeaderFields(endpoint: EndpointCustomHTTPHeaders(url: url, headers: [
            .init(name: "X-Proxy-Credential", value: "proxy-secret"),
            .init(name: "Authorization", value: "Bearer proxy-secret")
        ]))
    }

    private static func response(body: String) -> String {
        "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    private static func redirect(status: Int, location: String) -> String {
        "HTTP/1.1 \(status) Redirect\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    }

    private static func expectRefusal<T>(_ operation: () async throws -> T) async {
        do {
            _ = try await operation()
            Issue.record("Expected redirect refusal")
        } catch ActualAPIError.redirectRefused {
            #expect(!LocalFirstActualStore.isFailoverEligible(ActualAPIError.redirectRefused))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

/// Each server owns a private serial queue; the mutex protects observations read
/// by async tests while Network callbacks run on that queue.
private final class HeaderRedirectTestServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Actualist.HeaderRedirectTest")
    private let state = Mutex((ready: false, requests: [String]()))
    private let response: @Sendable (String) -> String

    init(response: @escaping @Sendable (String) -> String) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.response = response
    }

    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }
    var requests: [String] { state.withLock { $0.requests } }

    func start() async throws {
        listener.stateUpdateHandler = { [self] update in
            if case .ready = update { state.withLock { $0.ready = true } }
        }
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            receive(connection, collected: Data())
        }
        listener.start(queue: queue)
        for _ in 0..<200 {
            if state.withLock({ $0.ready }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }

    func stop() {
        listener.cancel()
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
    }

    private func receive(_ connection: NWConnection, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
            var bytes = collected
            if let data { bytes.append(data) }
            let headerEnd = bytes.range(of: Data("\r\n\r\n".utf8))?.upperBound
            let text = String(decoding: bytes, as: UTF8.self)
            let length = text.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            if let headerEnd, bytes.count >= headerEnd + length {
                state.withLock { $0.requests.append(text) }
                connection.send(content: Data(response(text).utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if !complete && error == nil {
                receive(connection, collected: bytes)
            } else {
                connection.cancel()
            }
        }
    }
}
