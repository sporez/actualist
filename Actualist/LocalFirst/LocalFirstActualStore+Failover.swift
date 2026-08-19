import Foundation

extension LocalFirstActualStore {
    /// Resolves the primary and optional fallback `URL` for a given server URL
    /// string. The fallback is only included when it is configured, non-empty,
    /// normalizes to a valid URL, and differs from the primary.
    func failoverEndpoints(
        for serverURLString: String
    ) -> (primary: URL?, fallback: URL?) {
        let primary = URL(string: ActualServerURLNormalizer.normalize(serverURLString))

        let fallbackRaw = fallbackServerURLString?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !fallbackRaw.isEmpty else {
            return (primary, nil)
        }
        let fallback = URL(string: ActualServerURLNormalizer.normalize(fallbackRaw))
        guard let primary, let fallback, fallback != primary else {
            return (primary, nil)
        }
        return (primary, fallback)
    }

    /// Returns `true` for errors that indicate the server could not be reached
    /// at all — the cases where trying a fallback endpoint is both safe and
    /// useful. Client-visible server errors (auth failures, 4xx/5xx application
    /// statuses, decoding errors) and mid-stream drops are excluded: failing
    /// over on those could mask real problems or, for writes, risk re-sending
    /// data the server already processed.
    ///
    /// Two pre-response failure families are explicitly eligible:
    /// - Transport errors where no HTTP bytes were exchanged, including
    ///   `.secureConnectionFailed` (TLS handshake aborts such as an SNI "no
    ///   such host" alert). The fallback connection validates TLS
    ///   independently, so no security decision from the failed attempt is
    ///   carried over.
    /// - Gateway statuses (502/503/504), which come from a reverse proxy whose
    ///   upstream Actual server is down. The server never produced a
    ///   response, and sync pushes re-sent through the fallback are
    ///   deduplicated by CRDT timestamp server-side.
    static func isFailoverEligible(_ error: Error) -> Bool {
        guard let apiError = error as? ActualAPIError else {
            return false
        }
        switch apiError {
        case .localNetworkDenied:
            return true
        case .transport(let code):
            guard let code else {
                return false
            }
            switch code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .secureConnectionFailed:
                return true
            default:
                return false
            }
        case .httpStatus(let status):
            return gatewayFailureStatuses.contains(status)
        default:
            return false
        }
    }

    /// HTTP statuses emitted by a reverse-proxy layer when the Actual server
    /// behind it is down: bad gateway, service unavailable, gateway timeout.
    static let gatewayFailureStatuses: Set<Int> = [502, 503, 504]

    /// Runs a sync operation against the primary endpoint, retrying against the
    /// fallback when the primary is unreachable. The operation closure receives
    /// the transport to use; the store builds it from the injected factory so
    /// tests can substitute stubs. When no fallback is configured this is a
    /// straight pass-through.
    ///
    /// Stamps `lastSyncEndpoint` to the endpoint actually tried so sync-status
    /// and debug-event recording can attribute the result to primary or
    /// fallback.
    func withSyncFailover<T>(
        serverURLString: String,
        operation: @escaping @Sendable (any ActualSyncTransport) async throws -> T
    ) async throws -> T {
        let endpoints = failoverEndpoints(for: serverURLString)
        guard let primaryURL = endpoints.primary else {
            throw ActualAPIError.invalidURL
        }
        let primaryTransport = syncTransport(for: primaryURL)
        lastSyncEndpoint = .primary
        do {
            let result = try await operation(primaryTransport)
            return result
        } catch {
            guard let fallbackURL = endpoints.fallback,
                  Self.isFailoverEligible(error) else {
                throw error
            }
            let fallbackTransport = syncTransport(for: fallbackURL)
            lastSyncEndpoint = .fallback
            return try await operation(fallbackTransport)
        }
    }

    /// Runs a connection-operation against the primary endpoint, retrying against
    /// the fallback when the primary is unreachable. See `withSyncFailover`.
    func withConnectionFailover<T>(
        serverURLString: String,
        operation: @escaping @Sendable (any ActualServerConnectionTransport) async throws -> T
    ) async throws -> T {
        let endpoints = failoverEndpoints(for: serverURLString)
        guard let primaryURL = endpoints.primary else {
            throw ActualAPIError.invalidURL
        }
        let primaryTransport = connectionTransport(for: primaryURL)
        lastSyncEndpoint = .primary
        do {
            let result = try await operation(primaryTransport)
            return result
        } catch {
            guard let fallbackURL = endpoints.fallback,
                  Self.isFailoverEligible(error) else {
                throw error
            }
            let fallbackTransport = connectionTransport(for: fallbackURL)
            lastSyncEndpoint = .fallback
            return try await operation(fallbackTransport)
        }
    }
}
