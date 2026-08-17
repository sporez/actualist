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

    /// Returns `true` for errors that indicate the server could not be reached at
    /// all — the cases where trying a fallback endpoint is both safe and useful.
    /// HTTP status errors, authentication failures, decoding errors, and mid-
    /// stream drops are excluded: failing over on those could mask real problems
    /// or, for writes, risk re-sending data the server already processed.
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
            case .cannotConnectToHost, .cannotFindHost, .timedOut:
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    /// Runs a sync operation against the primary endpoint, retrying against the
    /// fallback when the primary is unreachable. The operation closure receives
    /// the transport to use; the store builds it from the injected factory so
    /// tests can substitute stubs. When no fallback is configured this is a
    /// straight pass-through.
    func withSyncFailover<T>(
        serverURLString: String,
        operation: @escaping @Sendable (any ActualSyncTransport) async throws -> T
    ) async throws -> T {
        let endpoints = failoverEndpoints(for: serverURLString)
        guard let primaryURL = endpoints.primary else {
            throw ActualAPIError.invalidURL
        }
        let primaryTransport = syncTransportFactory(primaryURL)
        do {
            return try await operation(primaryTransport)
        } catch {
            guard let fallbackURL = endpoints.fallback,
                  Self.isFailoverEligible(error) else {
                throw error
            }
            let fallbackTransport = syncTransportFactory(fallbackURL)
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
        let primaryTransport = connectionTransportFactory(primaryURL)
        do {
            return try await operation(primaryTransport)
        } catch {
            guard let fallbackURL = endpoints.fallback,
                  Self.isFailoverEligible(error) else {
                throw error
            }
            let fallbackTransport = connectionTransportFactory(fallbackURL)
            return try await operation(fallbackTransport)
        }
    }
}
