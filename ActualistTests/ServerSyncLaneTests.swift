import Foundation
import Testing
@testable import Actualist

/// Transport that parks its first sync call until released, so a scheduled
/// flush can be held in flight while a background run starts.
private actor GatedSyncTransport: ActualSyncTransport {
    let inner: RecordingSyncTransport
    let entered = TestLatch()
    let release = TestLatch()
    private var hasParked = false

    init(inner: RecordingSyncTransport) { self.inner = inner }

    func sync(data: Data, token: String) async throws -> Data {
        if !hasParked {
            hasParked = true
            entered.trip()
            await release.wait()
        }
        return try await inner.sync(data: data, token: token)
    }
}

/// The per-session server-sync lane (concurrency 5.1, audit CA-15).
extension LocalFirstActualStoreTests {
    @Test func flushThatAppliesAnInsertDuringABackgroundRunCountsTowardIt() async throws {
        let recording = RecordingSyncTransport()
        try await recording.seedServerMessages([
            remoteMessage(index: 0, row: "lane-new", column: "acct", value: .string("checking")),
            remoteMessage(index: 1, row: "lane-new", column: "amount", value: .int(-4_200))
        ])
        let gated = GatedSyncTransport(inner: recording)
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in gated },
            pendingLocalMessageFlushRetryDelays: [.zero]
        )
        try bundle.keychain.saveActualSyncToken("token")
        var builder = LocalFirstSyncMessageBuilder()
        let draft = try builder.makeMessage(
            dataset: "accounts", row: "lane-write", column: "name", value: .string("Lane")
        )
        let database = try #require(bundle.store.database)
        #expect(try await database.commitLocalSyncMessagesAndEnqueue([draft]) == 1)
        bundle.store.openedServerURLString = "https://sync.example"
        await bundle.store.schedulePendingLocalMessageFlush(database: database, budgetID: "group-1")
        let flushTask = try #require(bundle.store.syncLane.scheduledFlushTask)
        let parked = await gated.entered.wait(timeout: .seconds(20)) { gated.release.trip() }
        #expect(parked)

        let queued = TestLatch()
        bundle.store.syncLane.onWaiterEnqueued = { queued.trip() }
        let budget = bundle.budget
        let run = Task {
            try await bundle.store.syncAndFindNewTransactions(
                budget: budget, serverURLString: "https://sync.example", openBudget: { _ in true }
            )
        }
        let waiting = await queued.wait(timeout: .seconds(20)) { gated.release.trip() }
        #expect(waiting)
        gated.release.trip()
        let results = try await run.value
        await flushTask.value

        #expect(results.count == 1)
        #expect(results.first?.newTransactionIDs == ["lane-new"])
    }

    @Test func anOlderOperationsFailureCannotOverwriteANewerSuccess() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let lane = bundle.store.syncLane
        let older = lane.nextTicket()
        let newer = lane.nextTicket()

        await bundle.store.recordSyncStatus(
            budgetID: "group-1", uploadedCount: 1, appliedCount: 2, error: nil, ticket: newer
        )
        await bundle.store.recordSyncStatus(
            budgetID: "group-1", uploadedCount: nil, appliedCount: nil,
            error: ActualAPIError.transport(.cannotConnectToHost), ticket: older
        )

        let status = try #require(bundle.store.syncStatus(budgetID: "group-1"))
        #expect(status.lastSyncedAt != nil)
        #expect(status.lastError == nil)
    }

    @Test func aCancelledRequestWaitingBehindARunningOperationReturnsPromptly() async throws {
        let lane = ServerSyncLane()
        let holding = TestLatch()
        let release = TestLatch()
        let holder = Task {
            try await lane.run(.flush) { _ in
                holding.trip()
                await release.wait()
            }
        }
        let held = await holding.wait(timeout: .seconds(20)) { release.trip() }
        #expect(held)

        let queued = TestLatch()
        lane.onWaiterEnqueued = { queued.trip() }
        let waiter = Task { try await lane.run(.pull) { _ in } }
        let enqueued = await queued.wait(timeout: .seconds(20)) { release.trip() }
        #expect(enqueued)
        waiter.cancel()

        // The holder is still parked: the waiter returned without waiting for it.
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(lane.waiterCount == 0)
        release.trip()
        try await holder.value
        #expect(lane.state == .idle)
    }

    @Test func requestsRunInOrderAndAnInvalidatedLaneRefusesNewOnes() async throws {
        let lane = ServerSyncLane()
        let holding = TestLatch()
        let release = TestLatch()
        let order = OrderRecorder()
        let first = Task {
            try await lane.run(.flush) { _ in
                holding.trip()
                await release.wait()
                order.append("first")
            }
        }
        let held = await holding.wait(timeout: .seconds(20)) { release.trip() }
        #expect(held)
        let queued = TestLatch()
        lane.onWaiterEnqueued = { queued.trip() }
        let second = Task { try await lane.run(.pull) { _ in order.append("second") } }
        let enqueued = await queued.wait(timeout: .seconds(20)) { release.trip() }
        #expect(enqueued)
        release.trip()
        try await first.value
        try await second.value
        #expect(order.values == ["first", "second"])

        lane.invalidate()
        await #expect(throws: CancellationError.self) { try await lane.run(.flush) { _ in } }
    }
}

@MainActor
private final class OrderRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
