import Foundation
import Testing
@testable import Actualist

@MainActor
private final class FakeBackgroundExecution: BackgroundExecutionAssertion {
    private(set) var begins = 0
    private(set) var ends = 0
    private(set) var active = 0
    private(set) var expirationHandlers: [@MainActor () -> Void] = []
    let firstEnd = TestLatch()

    func begin(
        name: String,
        onExpiration: @escaping @MainActor () -> Void
    ) -> any BackgroundExecutionHandle {
        begins += 1
        active += 1
        expirationHandlers.append(onExpiration)
        return Handle(owner: self)
    }

    private final class Handle: BackgroundExecutionHandle {
        let owner: FakeBackgroundExecution
        init(owner: FakeBackgroundExecution) { self.owner = owner }
        func end() {
            owner.ends += 1
            owner.active -= 1
            owner.firstEnd.trip()
        }
    }
}

/// Each outbox flush attempt holds exactly one background-execution assertion
/// (concurrency audit CA-04). Backoff sleeps between attempts hold none.
extension LocalFirstActualStoreTests {
    @Test func flushAttemptHoldsOneAssertionAndEndsItOnCompletion() async throws {
        let assertion = FakeBackgroundExecution()
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() },
            pendingLocalMessageFlushRetryDelays: [.zero],
            backgroundExecution: assertion
        )
        try bundle.keychain.saveActualSyncToken("token")
        try await enqueueAssertionDraft(in: bundle)

        await bundle.store.syncLane.scheduledFlushTask?.value

        #expect(assertion.begins == 1)
        #expect(assertion.ends == 1)
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == 0)
    }

    @Test func expirationCancelsTheAttemptAndEndsTheAssertionOnce() async throws {
        let assertion = FakeBackgroundExecution()
        let gate = ExpirationGate()
        let transport = RecordingSyncTransport()
        try await transport.seedServerMessages([
            remoteMessage(index: 0, row: "exp-new", column: "acct", value: .string("checking")),
            remoteMessage(index: 1, row: "exp-new", column: "amount", value: .int(-4_200))
        ])
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in transport },
            pendingLocalMessageFlushRetryDelays: [.zero],
            transactionFeedPageReadHook: { _, _, _, _ in
                guard gate.armed else { return }
                gate.armed = false
                gate.entered.trip()
                await gate.release.wait()
            },
            backgroundExecution: assertion
        )
        try bundle.keychain.saveActualSyncToken("token")
        try await bundle.store.refreshAccountTransactions(budgetID: "group-1", accountID: "checking")
        gate.armed = true
        try await enqueueAssertionDraft(in: bundle)
        let parked = await gate.entered.wait(timeout: .seconds(20)) { gate.release.trip() }
        #expect(parked)
        #expect(assertion.begins == 1)
        #expect(assertion.ends == 0)

        assertion.expirationHandlers.first?()
        gate.release.trip()
        await bundle.store.syncLane.scheduledFlushTask?.value

        #expect(assertion.begins == 1)
        #expect(assertion.ends == 1)
        // A cancelled attempt skips the success status tail.
        #expect(bundle.store.syncStatus(budgetID: "group-1")?.lastUploadedMessageCount == 0)
    }

    @Test func noAssertionIsHeldDuringTheBackoffSleep() async throws {
        let assertion = FakeBackgroundExecution()
        // Call 1 is the first upload; losing its response fails the first attempt.
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport(lostResponseAtCall: 1) },
            pendingLocalMessageFlushRetryDelays: [.zero, .seconds(30)],
            backgroundExecution: assertion
        )
        try bundle.keychain.saveActualSyncToken("token")
        try await enqueueAssertionDraft(in: bundle)
        let task = try #require(bundle.store.syncLane.scheduledFlushTask)

        // After the first attempt ends the loop can only be sleeping.
        let ended = await assertion.firstEnd.wait(timeout: .seconds(20)) { task.cancel() }
        #expect(ended)
        #expect(assertion.active == 0)
        task.cancel()
        await task.value

        #expect(assertion.begins == 1)
        #expect(assertion.ends == 1)
    }

    @MainActor
    private final class ExpirationGate {
        var armed = false
        let entered = TestLatch()
        let release = TestLatch()
    }

    private func enqueueAssertionDraft(in bundle: OpenedWritableStoreBundle) async throws {
        var builder = LocalFirstSyncMessageBuilder()
        let draft = try builder.makeMessage(
            dataset: "accounts",
            row: "assertion-write",
            column: "name",
            value: .string("Assertion")
        )
        let database = try #require(bundle.store.database)
        #expect(try await database.commitLocalSyncMessagesAndEnqueue([draft]) == 1)
        bundle.store.openedServerURLString = "https://sync.example"
        await bundle.store.schedulePendingLocalMessageFlush(database: database, budgetID: "group-1")
    }
}
