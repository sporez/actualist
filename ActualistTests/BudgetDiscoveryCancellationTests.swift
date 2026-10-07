import Foundation
import Testing
@testable import Actualist

/// Concurrency 5.5b (audit CA-19): discovery runs in a shared task that is
/// cancelled with its last waiting caller, not abandoned.
@MainActor
struct BudgetDiscoveryCancellationTests {
    private let fixtures = LocalFirstActualStoreTests()

    @Test func cancellingTheOnlyCallerCancelsTheDiscoveryRequest() async throws {
        let remote = ActualSyncRemoteFile(fileID: "remote", groupID: "remote-group", name: "Remote")
        let server = StubConnectionTransport(files: [remote], listUserFilesDelay: .seconds(30))
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(
            connectionTransportFactory: { _ in server }
        )
        try bundle.keychain.saveActualSyncToken("token")
        let state = try fixtures.makeAppState(for: bundle)
        bundle.store.reset()

        let call = Task { try await state.loadBudgets() }
        await server.waitForListUserFilesRequest()
        call.cancel()

        let finished = TestLatch()
        let observer = Task { _ = await call.result; finished.trip() }
        defer { observer.cancel() }
        let returned = await finished.wait(timeout: .seconds(10))
        #expect(returned, "the cancelled caller kept waiting for the discovery request")
    }
}
