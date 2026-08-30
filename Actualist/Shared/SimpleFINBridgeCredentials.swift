import Foundation

/// Errors from the SimpleFIN bridge (device-claim path, plan Phase 5).
/// Wording never echoes the token, access key, or host.
enum SimpleFINBridgeError: LocalizedError, Equatable {
    case invalidSetupToken
    case insecureURL
    case alreadyClaimed
    case invalidAccessURL
    case invalidResponse
    case unexpectedStatus(Int)
    case paymentRequired
    case accessRevoked

    var errorDescription: String? {
        switch self {
        case .invalidSetupToken:
            return "That setup token is not valid. Copy the complete token from SimpleFIN and try again."
        case .insecureURL:
            return "SimpleFIN returned a non-HTTPS address, which is not allowed. Nothing was saved."
        case .alreadyClaimed:
            return "SimpleFIN rejected this setup token, usually because it was already claimed. Disable it in SimpleFIN and create a new one."
        case .invalidAccessURL:
            return "SimpleFIN returned an unreadable access key."
        case .invalidResponse:
            return "SimpleFIN returned data this app could not read."
        case .unexpectedStatus(let status):
            return "SimpleFIN returned an unexpected response (\(status))."
        case .paymentRequired:
            return "SimpleFIN says this connection requires payment."
        case .accessRevoked:
            return "SimpleFIN access was denied. The connection may have been revoked."
        }
    }
}

/// Pure parsing for the device-claim path. No network, no Keychain.
/// The access key is parsed by hand — never with `URLComponents` — because
/// the password half may itself contain `:` or `@`.
enum SimpleFINBridgeCredentials {
    /// A SimpleFIN setup token is a (URL-safe) Base64-encoded HTTPS claim
    /// URL. Returns that URL; refuses anything not HTTPS.
    static func claimURL(fromSetupToken rawToken: String) throws -> URL {
        let token = rawToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = token + String(repeating: "=", count: (4 - token.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              let value = String(data: data, encoding: .utf8),
              let url = URL(string: value) else {
            throw SimpleFINBridgeError.invalidSetupToken
        }
        try requireHTTPS(url)
        return url
    }

    /// The claim response body is the access URL, e.g.
    /// `https://user:secret@bridge.example/user`. Parsed by hand: everything
    /// before the LAST `@` is the credential half, and the FIRST `:` inside
    /// it splits user from password. Passwords containing `@` or `:` parse
    /// correctly; `URLComponents` would not.
    static func accessCredentials(fromClaimBody rawBody: String) throws -> (username: String, password: String) {
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = "https://"
        guard body.lowercased().hasPrefix(scheme) else {
            throw SimpleFINBridgeError.insecureURL
        }
        let rest = body.dropFirst(scheme.count)
        guard let at = rest.lastIndex(of: "@") else {
            throw SimpleFINBridgeError.invalidAccessURL
        }
        let credentials = rest[..<at]
        guard let colon = credentials.firstIndex(of: ":") else {
            throw SimpleFINBridgeError.invalidAccessURL
        }
        let username = String(credentials[..<colon])
        let password = String(credentials[credentials.index(after: colon)...])
        guard !username.isEmpty, !password.isEmpty else {
            throw SimpleFINBridgeError.invalidAccessURL
        }
        return (username, password)
    }

    /// The host half of the access URL, without credentials. Used only to
    /// place the `/accounts` request; Basic auth is sent as a header built
    /// from the hand-parsed credentials, never from URL user/password.
    static func baseURL(fromClaimBody rawBody: String) throws -> URL {
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = "https://"
        guard body.lowercased().hasPrefix(scheme) else {
            throw SimpleFINBridgeError.insecureURL
        }
        let rest = body.dropFirst(scheme.count)
        guard let at = rest.lastIndex(of: "@") else {
            throw SimpleFINBridgeError.invalidAccessURL
        }
        guard let url = URL(string: scheme + rest[rest.index(after: at)...]) else {
            throw SimpleFINBridgeError.invalidAccessURL
        }
        try requireHTTPS(url)
        return url
    }

    static func basicAuthorization(username: String, password: String) -> String {
        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(credentials)"
    }

    static func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw SimpleFINBridgeError.insecureURL
        }
    }
}
