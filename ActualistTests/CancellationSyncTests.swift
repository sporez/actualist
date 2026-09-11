import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test(arguments: CancellationTestCase.allCases)
    func cancelledSyncKeepsOutboxAndTheLastRealConnectionError(_ kind: CancellationTestCase) async throws {
        let bundle = try await makeOpenedWritableStoreBundle(syncTransportFactory: { _ in
            CancelledSyncTransport(kind: kind)
        })
        try bundle.keychain.saveActualSyncToken("test")
        _ = try await bundle.store.assignCategoryBudgetAndRefresh(expectedMode: nil,
            categoryID: "groceries", budgeted: 62_500, budgetID: "group-1", month: "2026-07"
        ) {}
        let database = try #require(bundle.store.database)
        let before = try await database.pendingLocalSyncMessages()
        await bundle.store.recordSyncStatus(budgetID: "group-1", uploadedCount: nil, appliedCount: nil,
                                           error: ActualAPIError.transport(.cannotConnectToHost))
        let prior = bundle.store.syncStatus(budgetID: "group-1")
        do {
            try await bundle.store.refresh(budgetID: "group-1", serverURLString: "https://sync.example")
            Issue.record("Cancelled sync must not succeed")
        } catch {
            #expect(error.isCancellation)
        }
        let after = try await database.pendingLocalSyncMessages()
        #expect(!after.isEmpty)
        #expect(after.map(\.message) == before.map(\.message))
        #expect(after.allSatisfy { $0.attemptCount == 0 && $0.lastError == nil })
        let status = bundle.store.syncStatus(budgetID: "group-1")
        #expect(status?.lastError == prior?.lastError)
        #expect(status?.lastSyncedAt == prior?.lastSyncedAt)
        #expect(status?.pendingLocalMessageCount == before.count)

        let coordinator = AppSyncCoordinator()
        let result = await coordinator.refresh(budgetID: "group-1", serverURLString: "https://sync.example",
            force: true, store: bundle.store, onStart: {}, isBudgetCurrent: { true })
        #expect(result.outcome == .cancelledOrStale)
    }

    @Test(arguments: CancellationTestCase.allCases)
    func cancelledScheduledFlushDoesNotRetry(_ kind: CancellationTestCase) async throws {
        let transport = CountingCancelledSyncTransport(kind: kind)
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in transport },
            pendingLocalMessageFlushRetryDelays: [.zero, .zero, .zero]
        )
        try bundle.keychain.saveActualSyncToken("test")
        _ = try await bundle.store.assignCategoryBudgetAndRefresh(expectedMode: nil,
            categoryID: "groceries", budgeted: 62_500, budgetID: "group-1", month: "2026-07"
        ) {}
        let database = try #require(bundle.store.database)
        bundle.store.openedServerURLString = "https://sync.example"
        await bundle.store.runScheduledPendingLocalMessageFlush(database: database,
            budgetID: "group-1", serverURLString: "https://sync.example")
        #expect(await transport.attempts == 1)
        #expect(bundle.store.pendingLocalMessageFlushTask == nil)
        #expect(try await database.pendingLocalSyncMessageCount() > 0)
    }

}

private struct CancelledSyncTransport: ActualSyncTransport {
    let kind: CancellationTestCase
    func sync(data: Data, token: String) async throws -> Data { throw kind.error }
}


private actor CountingCancelledSyncTransport: ActualSyncTransport {
    let kind: CancellationTestCase
    private(set) var attempts = 0
    init(kind: CancellationTestCase) { self.kind = kind }
    func sync(data: Data, token: String) async throws -> Data {
        attempts += 1
        throw kind.error
    }
}
