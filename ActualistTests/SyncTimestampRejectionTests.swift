import Foundation
import Testing
@testable import Actualist

/// Actual's sync server (upstream #8905, after v26.11.0) refuses a `/sync` batch whose new messages
/// carry a timestamp it cannot parse or one more than five minutes past its own
/// clock, with a bare `invalid-timestamp` or `clock-drift` 400 body
/// (`packages/sync-server/src/sync-simple.js`, upstream #8905). The batch is
/// rolled back, so Actualist must say why instead of "The server had a problem".
@MainActor
struct SyncTimestampRejectionTests {
    private func rejection(_ token: String) -> ActualAPIError {
        ActualServerSyncClient.apiError(statusCode: 400, data: Data(token.utf8))
    }

    private func reason(of error: Error?) -> String? {
        guard case .syncRejected(400, let reason)? = error as? ActualAPIError else { return nil }
        return reason.rawValue
    }

    private func refreshError(_ syncError: ActualAPIError) async throws -> (error: Error?, lastError: String?) {
        let bundle = try await LocalFirstActualStoreTests().makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in ErroringSyncTransport(error: syncError) },
            pendingLocalMessageFlushRetryDelays: [.zero]
        )
        try bundle.keychain.saveActualSyncToken("token")
        do {
            _ = try await bundle.store.refresh(budgetID: "group-1", serverURLString: "https://sync.example")
            return (nil, bundle.store.syncStatus(budgetID: "group-1")?.lastError)
        } catch {
            return (error, bundle.store.syncStatus(budgetID: "group-1")?.lastError)
        }
    }

    @Test func serverRejectionTokensAreTyped() {
        #expect(reason(of: rejection("clock-drift")) == "clock-drift")
        #expect(reason(of: rejection("invalid-timestamp")) == "invalid-timestamp")
        // An unrelated body keeps the generic status error.
        if case .httpStatus(400) = rejection("something-else") {} else {
            Issue.record("an unknown 400 body must stay .httpStatus(400)")
        }
    }

    @Test func serverClockDriftReportsTheClockProblem() async throws {
        let result = try await refreshError(rejection("clock-drift"))
        #expect((result.error as? LocalFirstError) == .clockDrift)
        #expect(result.lastError == LocalFirstError.clockDrift.localizedDescription)
    }

    @Test func serverInvalidTimestampIsNotAGenericServerProblem() async throws {
        let result = try await refreshError(rejection("invalid-timestamp"))
        #expect(reason(of: result.error) == "invalid-timestamp")
        let generic = ActualAPIError.httpStatus(400).localizedDescription
        #expect(result.error?.localizedDescription != generic)
        #expect(result.lastError != generic)
    }
}
