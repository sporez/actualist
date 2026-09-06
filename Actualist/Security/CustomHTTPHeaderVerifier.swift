import Foundation

struct CustomHTTPHeaderVerification: Equatable, Sendable {
    let requiresHeaders: Bool

    var title: String { requiresHeaders ? "Headers verified" : "Connection successful" }
    var message: String {
        requiresHeaders
            ? "This server requires the configured custom headers."
            : "This server also accepts requests without these headers, so their presence cannot be independently verified."
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
        let withoutHeaders = ActualServerSyncClient(baseURL: url, session: session)
        do {
            _ = try await withoutHeaders.loginMethods()
            try Task.checkCancellation()
            return CustomHTTPHeaderVerification(requiresHeaders: false)
        } catch {
            try Task.checkCancellation()
            return CustomHTTPHeaderVerification(requiresHeaders: !headers.isEmpty)
        }
    }
}
