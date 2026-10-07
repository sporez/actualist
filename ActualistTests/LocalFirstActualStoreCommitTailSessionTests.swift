import Foundation
import Testing
@testable import Actualist

/// An attached-tail reload that awaits a read must not publish into caches a
/// retired session already cleared (main-to-dev 2.3).
@MainActor
struct LocalFirstActualStoreCommitTailSessionTests {
    private let support = LocalFirstActualStoreTests()

    private func makeStore() async throws -> LocalFirstActualStore {
        try await support.makeOpenedWritableStoreBundle().store
    }

    @Test func payeeWriteTailDoesNotRepopulateCachesAfterTheSessionCloses() async throws {
        let store = try await makeStore()
        store.payeeSnapshotReadHook = { [store] _ in store.closeOpenBudget() }

        try await store.createPayeeAndRefresh(budgetID: "group-1", name: "Late Payee")

        #expect(store.cachedPayeeManagementSnapshot(budgetID: "group-1") == nil)
    }

    @Test func standalonePayeeRefreshDoesNotRepopulateCachesAfterTheSessionCloses() async throws {
        let store = try await makeStore()
        store.payeeSnapshotReadHook = { [store] _ in store.closeOpenBudget() }

        await #expect(throws: CancellationError.self) {
            try await store.refreshPayeeManagementSnapshot(budgetID: "group-1")
        }

        #expect(store.cachedPayeeManagementSnapshot(budgetID: "group-1") == nil)
    }
}
