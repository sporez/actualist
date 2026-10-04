import Foundation
import Testing
@testable import Actualist

/// One flush uploads at most 500 outbox rows (`pendingLocalSyncMessages(limit:)`).
/// A larger outbox must keep draining until empty or until an upload fails.
extension LocalFirstActualStoreTests {
    @Test func outboxLargerThanOneBatchDrainsInBatches() async throws {
        let transport = RecordingSyncTransport()
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in transport },
            pendingLocalMessageFlushRetryDelays: [.zero]
        )
        try bundle.keychain.saveActualSyncToken("token")
        try await enqueueOutboxDrafts(1_100, in: bundle)

        try await flushScheduledOutbox(in: bundle)

        // Each upload is followed by one empty confirmation pull.
        #expect(await transport.messageCounts().filter { $0 > 0 } == [500, 500, 100])
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == 0)
        #expect(bundle.store.syncStatus(budgetID: "group-1")?.lastUploadedMessageCount == 1_100)
        #expect(bundle.store.syncStatus(budgetID: "group-1")?.lastError == nil)
    }

    @Test func failedSecondBatchKeepsTheUnconfirmedRowsQueued() async throws {
        // Request 3 is the second upload (request 2 is the first upload's confirmation pull).
        let transport = RecordingSyncTransport(lostResponseAtCall: 3)
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in transport },
            pendingLocalMessageFlushRetryDelays: [.zero]
        )
        try bundle.keychain.saveActualSyncToken("token")
        try await enqueueOutboxDrafts(1_100, in: bundle)

        try await flushScheduledOutbox(in: bundle)

        #expect(await transport.messageCounts().filter { $0 > 0 } == [500, 500])
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == 600)
        #expect(bundle.store.syncStatus(budgetID: "group-1")?.lastError != nil)
    }

    private func enqueueOutboxDrafts(
        _ count: Int,
        in bundle: OpenedWritableStoreBundle
    ) async throws {
        var builder = LocalFirstSyncMessageBuilder()
        let drafts = try (0..<count).map { index in
            try builder.makeMessage(
                dataset: "accounts",
                row: "bulk-\(index)",
                column: "name",
                value: .string("Bulk \(index)")
            )
        }
        let database = try #require(bundle.store.database)
        #expect(try await database.commitLocalSyncMessagesAndEnqueue(drafts) == count)
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == count)
    }

    private func flushScheduledOutbox(in bundle: OpenedWritableStoreBundle) async throws {
        let database = try #require(bundle.store.database)
        bundle.store.openedServerURLString = "https://sync.example"
        await bundle.store.schedulePendingLocalMessageFlush(database: database, budgetID: "group-1")
        await bundle.store.pendingLocalMessageFlushTask?.value
    }
}
