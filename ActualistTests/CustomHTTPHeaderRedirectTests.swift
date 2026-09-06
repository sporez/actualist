import Foundation
import Network
import Synchronization
import Testing
@testable import Actualist

struct CustomHTTPHeaderRedirectTests {
    @Test func liveRedirectsProtectAllThreeTransportPaths() async throws {
        let receiver = try HeaderRedirectTestServer { _ in
            "HTTP/1.1 200 OK\r\nContent-Length: 24\r\nConnection: close\r\n\r\n{\"methods\":[\"password\"]}"
        }
        try await receiver.start()
        defer { receiver.stop() }
        let target = URL(string: receiver.url.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost"))!
        let origin = try HeaderRedirectTestServer { request in
            if request.hasPrefix("GET /same/") || request.hasPrefix("POST /same/") {
                return "HTTP/1.1 307 Temporary Redirect\r\nLocation: /final\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            }
            if request.hasPrefix("GET /final") || request.hasPrefix("POST /final") {
                let body = "{\"methods\":[\"password\"],\"configured\":true}"
                return "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            }
            return "HTTP/1.1 307 Temporary Redirect\r\nLocation: \(target.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
        try await origin.start()
        defer { origin.stop() }
        let endpoint = try EndpointCustomHTTPHeaders(url: origin.url, headers: [
            .init(name: "X-Proxy-Credential", value: "redirect-secret"),
            .init(name: "Authorization", value: "Bearer redirect-secret")
        ])
        let fields = try HTTPHeaderFields(endpoint: endpoint)
        for path in ["same", "cross"] {
            let baseURL = origin.url.appending(path: path)
            let client = ActualServerSyncClient(baseURL: baseURL, customHeaders: fields, firstConnectionRetryDelays: [])
            _ = try await client.loginMethods()
            _ = try await client.sync(data: Data(), token: "actual-token")
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            try await client.downloadUserFile(fileID: "file", token: "actual-token", to: file)
            let bank = ActualServerSimpleFINClient(baseURL: baseURL, customHeaders: fields)
            _ = try? await bank.simpleFINStatus(token: "actual-token")
        }
        let same = origin.requests.filter { $0.contains(" /final ") }
        #expect(same.count == 4)
        #expect(same.allSatisfy { $0.lowercased().contains("x-proxy-credential: redirect-secret") })
        #expect(same.allSatisfy { $0.lowercased().contains("authorization: bearer redirect-secret") })
        #expect(receiver.requests.count == 4)
        #expect(receiver.requests.allSatisfy { !$0.contains("redirect-secret") })
    }
}

/// Each server owns a private serial queue; the mutex protects observations read
/// by the async test while Network callbacks run on that queue.
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
            let text = String(decoding: bytes, as: UTF8.self)
            if text.contains("\r\n\r\n") {
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
