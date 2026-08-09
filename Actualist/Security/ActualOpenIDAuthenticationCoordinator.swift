import AuthenticationServices
import Foundation
import Security

typealias ActualOpenIDBrowserSession = @MainActor @Sendable (URL) async throws -> URL

enum ActualOpenIDAuthenticationError: LocalizedError, Equatable {
    case alreadyInProgress
    case cancelled
    case invalidAuthorizationURL
    case invalidCallback
    case missingToken
    case ambiguousToken
    case nonceGenerationFailed

    var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            "An OpenID sign-in is already in progress."
        case .cancelled:
            "OpenID sign-in was cancelled."
        case .invalidAuthorizationURL:
            "The Actual server returned an invalid OpenID authorization URL."
        case .invalidCallback:
            "Actualist could not verify the OpenID sign-in response."
        case .missingToken:
            "The OpenID sign-in response did not include an Actual session token."
        case .ambiguousToken:
            "The OpenID sign-in response included an ambiguous Actual session token."
        case .nonceGenerationFailed:
            "Actualist could not securely begin OpenID sign-in."
        }
    }
}

struct ActualOpenIDCallbackParser {
    static func token(from callbackURL: URL, expectedNonce: String) throws -> String {
        guard callbackURL.scheme == ActualOpenIDAuthenticationCoordinator.callbackScheme,
              callbackURL.host == ActualOpenIDAuthenticationCoordinator.callbackHost,
              callbackURL.path == "/openid/\(expectedNonce)/openid-cb",
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw ActualOpenIDAuthenticationError.invalidCallback
        }

        let tokens = (components.queryItems ?? []).filter { $0.name == "token" }
        guard tokens.count <= 1 else {
            throw ActualOpenIDAuthenticationError.ambiguousToken
        }
        guard let token = tokens.first?.value,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ActualOpenIDAuthenticationError.missingToken
        }
        return token
    }
}

actor ActualOpenIDAuthenticationCoordinator {
    static let callbackScheme = "com.sporez.actualist"
    static let callbackHost = "localhost"

    private var activeNonce: String?

    func authenticate(
        client: any ActualServerConnectionTransport,
        firstTimeLoginPassword: String? = nil,
        browserSession: @escaping ActualOpenIDBrowserSession
    ) async throws -> String {
        guard activeNonce == nil else {
            throw ActualOpenIDAuthenticationError.alreadyInProgress
        }

        let nonce = try Self.makeNonce()
        activeNonce = nonce
        defer { activeNonce = nil }

        let callbackURL = try Self.callbackURL(nonce: nonce)
        let response = try await client.beginOpenIDLogin(
            returnURL: callbackURL,
            firstTimeLoginPassword: firstTimeLoginPassword
        )
        guard let scheme = response.returnURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              response.returnURL.host != nil else {
            throw ActualOpenIDAuthenticationError.invalidAuthorizationURL
        }

        let returnedURL: URL
        do {
            returnedURL = try await browserSession(response.returnURL)
        } catch {
            if Self.isCancellation(error) {
                throw ActualOpenIDAuthenticationError.cancelled
            }
            throw error
        }

        return try ActualOpenIDCallbackParser.token(
            from: returnedURL,
            expectedNonce: nonce
        )
    }

    private static func callbackURL(nonce: String) throws -> URL {
        var components = URLComponents()
        // Actual Server currently validates the return URL by hostname and explicitly accepts
        // localhost before appending /openid-cb. A private custom scheme lets the system web
        // authentication session return that redirect to Actualist without implementing OIDC.
        // Contract: actualbudget/actual sync-server app-account.js and accounts/openid.ts.
        components.scheme = callbackScheme
        components.host = callbackHost
        components.path = "/openid/\(nonce)"
        guard let url = components.url else {
            throw ActualOpenIDAuthenticationError.invalidCallback
        }
        return url
    }

    private static func makeNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ActualOpenIDAuthenticationError.nonceGenerationFailed
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let error = error as NSError
        return error.domain == ASWebAuthenticationSessionErrorDomain
            && error.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
    }
}
