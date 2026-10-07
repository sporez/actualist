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

    // MARK: A write that lands while the scheduled flush is in its tail

    @Test func writeArrivingInTheFlushTailStartsAnotherPass() async throws {
        let (bundle, transport, gate) = try await makeParkedFlushTail()
        let store = bundle.store
        let task = try #require(store.syncLane.scheduledFlushTask)

        try await commitLateWriteWhileParked(in: bundle)
        gate.release.trip()
        await task.value

        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") == 0)
        #expect(await transport.messageCounts().filter { $0 > 0 }.count == 2)
    }

    @Test func flushTailRequestIsIgnoredWhenTheServerChangedWhileParked() async throws {
        let (bundle, transport, gate) = try await makeParkedFlushTail()
        let store = bundle.store
        let task = try #require(store.syncLane.scheduledFlushTask)

        try await commitLateWriteWhileParked(in: bundle)
        store.openedServerURLString = "https://other.example"
        gate.release.trip()
        await task.value

        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") == 1)
        #expect(await transport.messageCounts().filter { $0 > 0 }.count == 1)
    }

    @MainActor
    private final class FlushTailGate {
        var armed = false
        let entered = TestLatch()
        let release = TestLatch()
    }

    /// Starts a scheduled flush whose upload succeeds and whose reload tail
    /// (after the serialized loop) is parked in a transaction feed read.
    private func makeParkedFlushTail() async throws -> (
        OpenedWritableStoreBundle, RecordingSyncTransport, FlushTailGate
    ) {
        let gate = FlushTailGate()
        let transport = RecordingSyncTransport()
        try await transport.seedServerMessages([
            remoteMessage(index: 0, row: "tail-new", column: "acct", value: .string("checking")),
            remoteMessage(index: 1, row: "tail-new", column: "amount", value: .int(-4_200))
        ])
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in transport },
            pendingLocalMessageFlushRetryDelays: [.zero],
            transactionFeedPageReadHook: { _, _, _, _ in
                guard gate.armed else { return }
                gate.armed = false
                gate.entered.trip()
                await gate.release.wait()
            }
        )
        try bundle.keychain.saveActualSyncToken("token")
        try await bundle.store.refreshAccountTransactions(budgetID: "group-1", accountID: "checking")
        try await enqueueOutboxDrafts(1, in: bundle)
        let database = try #require(bundle.store.database)
        bundle.store.openedServerURLString = "https://sync.example"
        gate.armed = true
        await bundle.store.schedulePendingLocalMessageFlush(database: database, budgetID: "group-1")
        let parked = await gate.entered.wait(timeout: .seconds(20)) { gate.release.trip() }
        #expect(parked)
        return (bundle, transport, gate)
    }

    private func commitLateWriteWhileParked(in bundle: OpenedWritableStoreBundle) async throws {
        var builder = LocalFirstSyncMessageBuilder()
        let draft = try builder.makeMessage(
            dataset: "accounts",
            row: "late-write",
            column: "name",
            value: .string("Late")
        )
        let database = try #require(bundle.store.database)
        #expect(try await database.commitLocalSyncMessagesAndEnqueue([draft]) == 1)
        await bundle.store.schedulePendingLocalMessageFlush(database: database, budgetID: "group-1")
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
        await bundle.store.syncLane.scheduledFlushTask?.value
    }
}
