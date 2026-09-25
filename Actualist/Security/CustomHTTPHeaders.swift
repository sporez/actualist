import Foundation

struct HTTPOrigin: Codable, Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    static func validatedURL(from input: String) -> URL? {
        URL(string: ActualServerURLNormalizer.normalize(input))
            .flatMap { (try? HTTPOrigin(url: $0)) == nil ? nil : $0 }
    }

    init(url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw ActualAPIError.invalidURL
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { throw ActualAPIError.invalidURL }
        self.scheme = scheme
        self.host = host
        self.port = port
    }
}

enum ActualServerEndpointRole: String, CaseIterable, Sendable {
    case primary, fallback

    var title: String { self == .primary ? "Primary Server" : "Fallback Server" }
}

struct CustomHTTPHeader: Codable, Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var id = UUID()
    var name: String
    var value: String

    var description: String { "CustomHTTPHeader(<redacted>)" }
    var debugDescription: String { description }
}

struct EndpointCustomHTTPHeaders: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let origin: HTTPOrigin
    let headers: [CustomHTTPHeader]

    init(url: URL, headers: [CustomHTTPHeader]) throws {
        origin = try HTTPOrigin(url: url)
        self.headers = try HTTPHeaderFields.validate(headers)
    }

    private enum CodingKeys: String, CodingKey { case origin, headers }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        origin = try container.decode(HTTPOrigin.self, forKey: .origin)
        headers = try HTTPHeaderFields.validate(container.decode([CustomHTTPHeader].self, forKey: .headers))
    }

    func applies(to url: URL) -> Bool { (try? HTTPOrigin(url: url)) == origin }
    var description: String { "EndpointCustomHTTPHeaders(\(headers.count) fields)" }
    var debugDescription: String { description }
}

struct CustomHTTPHeaderConfiguration: Codable, Equatable, Sendable {
    var primary: EndpointCustomHTTPHeaders?
    var fallback: EndpointCustomHTTPHeaders?

    subscript(role: ActualServerEndpointRole) -> EndpointCustomHTTPHeaders? {
        get { role == .primary ? primary : fallback }
        set {
            if role == .primary { primary = newValue } else { fallback = newValue }
        }
    }

    func fields(for role: ActualServerEndpointRole, url: URL) throws -> HTTPHeaderFields {
        guard let endpoint = self[role], endpoint.applies(to: url) else { return .empty }
        return try HTTPHeaderFields(endpoint: endpoint)
    }
}

enum CustomHTTPHeaderError: LocalizedError, Equatable {
    case invalidName, invalidValue, duplicateName, reservedName, unreadableConfiguration

    var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a valid HTTP header name using letters, numbers, or HTTP token punctuation."
        case .invalidValue: "Header values cannot contain line breaks or control characters."
        case .duplicateName: "Each header name must be unique, regardless of capitalization."
        case .reservedName: "This header is controlled by Actualist or the network transport."
        case .unreadableConfiguration: "Saved custom headers could not be read. Unlock this device and try again."
        }
    }
}

/// Immutable transport input. Decoded Keychain rows are revalidated before use.
struct HTTPHeaderFields: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    static let empty = HTTPHeaderFields()
    private let endpoint: EndpointCustomHTTPHeaders?

    private init() { endpoint = nil }
    init(endpoint: EndpointCustomHTTPHeaders) throws {
        _ = try Self.validate(endpoint.headers)
        self.endpoint = endpoint
    }

    static let reservedNames: Set<String> = [
        "x-actual-token", "x-actual-file-id", "accept", "content-type", "content-length",
        "host", "connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade",
        "proxy-authenticate", "proxy-authorization"
    ]

    static func validate(_ headers: [CustomHTTPHeader]) throws -> [CustomHTTPHeader] {
        let punctuation = "!#$%&'*+-.^_`|~"
        var names = Set<String>()
        return try headers.map { header in
            var normalized = header
            normalized.name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.name.isEmpty, normalized.name.utf8.allSatisfy({ byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                    || punctuation.utf8.contains(byte)
            }) else { throw CustomHTTPHeaderError.invalidName }
            let name = normalized.name.lowercased()
            guard !reservedNames.contains(name) else { throw CustomHTTPHeaderError.reservedName }
            guard names.insert(name).inserted else { throw CustomHTTPHeaderError.duplicateName }
            guard !header.value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw CustomHTTPHeaderError.invalidValue
            }
            return normalized
        }
    }

    func apply(to request: inout URLRequest) {
        guard let url = request.url else { return }
        for (name, value) in initialBrowserHeaders(for: url) {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    func initialBrowserHeaders(for url: URL) -> [String: String] {
        guard let endpoint, endpoint.applies(to: url) else { return [:] }
        return Dictionary(uniqueKeysWithValues: endpoint.headers.map { ($0.name, $0.value) })
    }

    func redirectRequest(_ request: URLRequest, from sourceURL: URL?) -> URLRequest {
        var result = request
        guard let endpoint else { return result }
        let sourceMatches = sourceURL.map(endpoint.applies(to:)) ?? false
        let destinationMatches = request.url.map(endpoint.applies(to:)) ?? false
        if sourceMatches && destinationMatches {
            // URLSession drops Authorization even on some same-origin redirects.
            // Restore only within the endpoint's origin, never on a return from
            // another origin after credentials have been stripped.
            apply(to: &result)
        } else {
            for header in endpoint.headers { result.setValue(nil, forHTTPHeaderField: header.name) }
        }
        return result
    }

    /// Servers can echo credentials in error bodies. With custom credentials,
    /// retain the status but never expose arbitrary server-provided text.
    func sanitized(_ error: ActualAPIError) -> ActualAPIError {
        guard endpoint?.headers.isEmpty == false else { return error }
        if case .serverRejected(let status, _, _) = error {
            if error.isAuthenticationFailure { return .httpStatus(status ?? 401) }
            return status.map(ActualAPIError.httpStatus) ?? .invalidResponse
        }
        return error
    }

    func containsCredential(in text: String?) -> Bool {
        guard let text else { return false }
        return endpoint?.headers.contains { !$0.value.isEmpty && text.contains($0.value) } ?? false
    }

    var description: String { "HTTPHeaderFields(\(endpoint?.headers.count ?? 0) fields)" }
    var debugDescription: String { description }
}

/// Per-task delegate protects injected sessions as well as production sessions.
final class CustomHTTPHeaderRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let fields: HTTPHeaderFields
    private let endpointOrigin: HTTPOrigin?

    init(baseURL: URL, fields: HTTPHeaderFields) {
        self.fields = fields
        endpointOrigin = try? HTTPOrigin(url: baseURL)
    }

    func permits(source: URL?, destination: URL?) -> Bool {
        guard let endpointOrigin,
              let source, let destination,
              (try? HTTPOrigin(url: source)) == endpointOrigin,
              (try? HTTPOrigin(url: destination)) == endpointOrigin else { return false }
        return true
    }

    func refuses(_ response: HTTPURLResponse) -> Bool {
        guard [301, 302, 303, 307, 308].contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location") else { return false }
        return !permits(
            source: response.url,
            destination: URL(string: location, relativeTo: response.url)?.absoluteURL
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard permits(source: response.url, destination: request.url) else {
            completionHandler(nil)
            return
        }
        completionHandler(fields.redirectRequest(request, from: response.url))
    }
}
