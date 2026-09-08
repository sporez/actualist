import Foundation

enum CustomHTTPHeaderVerification: Equatable, Sendable {
    case noHeaders, acceptsWithAndWithoutHeaders, comparisonFailed

    var title: String { "Connection successful" }
    var message: String {
        switch self {
        case .noHeaders:
            "The server is reachable. No custom headers were included."
        case .acceptsWithAndWithoutHeaders:
            "The server accepted requests with and without these headers. This test cannot confirm whether it used them."
        case .comparisonFailed:
            "The request with headers succeeded. The request without them failed, so these headers may be required."
        }
    }
}

struct CustomHTTPHeaderVerifier: Sendable {
    var session: URLSession?

    func verify(url: URL, headers: [CustomHTTPHeader]) async throws -> CustomHTTPHeaderVerification {
        try Task.checkCancellation()
        if ActualServerConnectionSecurity.blockedMessage(for: url.absoluteString) != nil {
            throw ActualAPIError.invalidURL
        }
        let fields = try HTTPHeaderFields(endpoint: EndpointCustomHTTPHeaders(url: url, headers: headers))
        let withHeaders = ActualServerSyncClient(baseURL: url, customHeaders: fields, session: session)
        _ = try await withHeaders.loginMethods()
        try Task.checkCancellation()
        guard !headers.isEmpty else { return .noHeaders }
        let withoutHeaders = ActualServerSyncClient(baseURL: url, session: session)
        do {
            _ = try await withoutHeaders.loginMethods()
            try Task.checkCancellation()
            return .acceptsWithAndWithoutHeaders
        } catch {
            try Task.checkCancellation()
            return .comparisonFailed
        }
    }
}
