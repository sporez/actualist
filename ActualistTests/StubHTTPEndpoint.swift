import Foundation
import Synchronization

/// A scripted HTTP responder owned by one test. Each endpoint registers under
/// a private token; the session it vends carries that token as a header, so
/// `StubHTTPProtocol` routes the request to this endpoint's own state instead
/// of shared static variables. Two tests, or two suites, can run concurrently
/// without seeing each other's response or recorded request. The token header
/// is stripped from the recorded request.
final class StubHTTPEndpoint: Sendable {
    private struct State {
        var statusCode: Int
        var body: String
        var lastRequest: URLRequest?
        var lastRequestBody: Data?
    }

    private let token = UUID().uuidString
    private let state: Mutex<State>

    init(statusCode: Int = 200, body: String = "") {
        state = Mutex(State(statusCode: statusCode, body: body))
        StubHTTPProtocol.register(self, token: token)
    }

    deinit { StubHTTPProtocol.unregister(token: token) }

    func respond(statusCode: Int, body: String) {
        state.withLock {
            $0.statusCode = statusCode
            $0.body = body
        }
    }

    var lastRequest: URLRequest? { state.withLock { $0.lastRequest } }
    var lastRequestBody: Data? { state.withLock { $0.lastRequestBody } }

    func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTPProtocol.self]
        configuration.httpAdditionalHeaders = [StubHTTPProtocol.tokenHeader: token]
        return configuration
    }

    func makeSession() -> URLSession { URLSession(configuration: makeConfiguration()) }

    fileprivate func handle(_ request: URLRequest) -> (statusCode: Int, body: String) {
        var recorded = request
        recorded.setValue(nil, forHTTPHeaderField: StubHTTPProtocol.tokenHeader)
        let body = request.httpBodyStream.flatMap(StubHTTPProtocol.read(stream:)) ?? request.httpBody
        return state.withLock {
            $0.lastRequest = recorded
            $0.lastRequestBody = body
            return ($0.statusCode, $0.body)
        }
    }
}

final class StubHTTPProtocol: URLProtocol {
    static let tokenHeader = "X-Actualist-Stub-Token"
    private static let endpoints = Mutex<[String: Weak]>([:])

    private final class Weak: @unchecked Sendable {
        weak var endpoint: StubHTTPEndpoint?
        init(_ endpoint: StubHTTPEndpoint) { self.endpoint = endpoint }
    }

    fileprivate static func register(_ endpoint: StubHTTPEndpoint, token: String) {
        endpoints.withLock { $0[token] = Weak(endpoint) }
    }

    fileprivate static func unregister(token: String) {
        endpoints.withLock { _ = $0.removeValue(forKey: token) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: Self.tokenHeader)
        guard let token, let endpoint = Self.endpoints.withLock({ $0[token]?.endpoint }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (statusCode, body) = endpoint.handle(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    fileprivate static func read(stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
