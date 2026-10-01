import Foundation
import SwiftProtobuf
import Testing
@testable import Actualist

@MainActor
@Suite("Local-first schedule posting")
struct LocalFirstActualStoreSchedulePostingTests {
    private let support = LocalFirstActualStoreTests()

    @Test func successfulSyncThenPostCreatesScheduledTransactionAndOutboxAtomically() async throws {
        let transport = RecordingSyncTransport()
        let bundle = try await makeBundle(transport: transport)
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let store = bundle.store
        let database = try #require(store.database)
        let review = try await store.schedulePostingReview(budgetID: "group-1", scheduleID: "rent")
        let outboxObservation = SchedulePostingOutboxObservation()
        store.scheduleMutationAfterCommitHook = {
            await outboxObservation.capturePendingCount(database: database)
        }
        defer { store.scheduleMutationAfterCommitHook = nil }

        let receipt = try await store.postSchedule(review: review, date: .scheduled)

        #expect(receipt.scheduleID == "rent")
        #expect(receipt.postedDayID == Self.today())
        #expect(!receipt.refreshPending)
        let posted = try #require(try await database.fetchTransaction(id: receipt.transactionID))
        #expect(posted.schedule == "rent")
        #expect(posted.amount == -10_000)
        #expect(posted.cleared?.boolValue == false)
        #expect((outboxObservation.pendingCount ?? 0) > 0)
        #expect(try await database.fetchSchedules(budgetID: "group-1", today: Self.today())
            .detail(id: "rent")?.status == .paid)
    }

    @Test func failedRemoteSyncLeavesOccurrenceAndOutboxUntouched() async throws {
        let transport = RecordingSyncTransport(shouldFail: true)
        let bundle = try await makeBundle(transport: transport)
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let store = bundle.store
        let database = try #require(store.database)
        let review = try await store.schedulePostingReview(budgetID: "group-1", scheduleID: "rent")
        let pendingBefore = try await database.pendingLocalSyncMessageCount()

        await #expect(throws: LocalFirstTestSyncError.self) {
            try await store.postSchedule(review: review, date: .scheduled)
        }

        #expect(try await database.pendingLocalSyncMessageCount() == pendingBefore)
        #expect(try await database.fetchSchedules(budgetID: "group-1", today: Self.today())
            .detail(id: "rent")?.status == .due)
    }

    @Test func occurrencePaidByPeerDuringSyncIsRejectedFromFreshStatus() async throws {
        let fixtureSupport = LocalFirstActualStoreTests()
        let messages = [
            fixtureSupport.remoteMessage(index: 1, row: "peer-posted", column: "acct", value: .string("checking")),
            fixtureSupport.remoteMessage(index: 2, row: "peer-posted", column: "date", value: .int(Int64(Self.packedToday))),
            fixtureSupport.remoteMessage(index: 3, row: "peer-posted", column: "amount", value: .int(-10_000)),
            fixtureSupport.remoteMessage(index: 4, row: "peer-posted", column: "schedule", value: .string("rent")),
            fixtureSupport.remoteMessage(index: 5, row: "peer-posted", column: "tombstone", value: .bool(false))
        ]
        let transport = SchedulePostingResponseTransport(messages: try messages.map {
            try LocalFirstSyncMessageBuilder.envelope(for: $0)
        })
        let bundle = try await makeBundle(transport: transport, fixtureSupport: fixtureSupport)
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let store = bundle.store
        let database = try #require(store.database)
        let review = try await store.schedulePostingReview(budgetID: "group-1", scheduleID: "rent")

        await #expect(throws: SchedulePostingError.occurrenceNoLongerPostable) {
            try await store.postSchedule(review: review, date: .scheduled)
        }

        #expect(try await database.fetchTransaction(id: "peer-posted")?.schedule == "rent")
        #expect(try await database.fetchTransaction(id: "peer-posted")?.amount == -10_000)
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
    }

    @Test func cancellationAfterCommitStillReturnsDurablePostReceipt() async throws {
        let transport = RecordingSyncTransport()
        let bundle = try await makeBundle(transport: transport)
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let store = bundle.store
        let database = try #require(store.database)
        let review = try await store.schedulePostingReview(budgetID: "group-1", scheduleID: "rent")
        let gate = SchedulePostingCommitGate()
        let outboxObservation = SchedulePostingOutboxObservation()
        store.scheduleMutationAfterCommitHook = {
            await outboxObservation.capturePendingCount(database: database)
            await gate.pause()
        }
        defer {
            store.scheduleMutationAfterCommitHook = nil
            gate.release()
        }

        let posting = Task {
            try await store.postSchedule(review: review, date: .scheduled)
        }
        do {
            try await gate.waitForEntry()
        } catch {
            posting.cancel()
            gate.release()
            _ = await posting.result
            throw error
        }
        #expect(gate.didEnter)
        posting.cancel()
        gate.release()

        let receipt = try await posting.value
        #expect(try await database.fetchTransaction(id: receipt.transactionID)?.schedule == "rent")
        #expect((outboxObservation.pendingCount ?? 0) > 0)
    }

    @Test func sameClientGateRejectsConcurrentPostAndReleasesAfterCanceledSync() async throws {
        let transport = GatedSchedulePostingSyncTransport()
        let bundle = try await makeBundle(transport: transport)
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let store = bundle.store
        let database = try #require(store.database)
        let review = try await store.schedulePostingReview(budgetID: "group-1", scheduleID: "rent")

        let first = Task { try await store.postSchedule(review: review, date: .scheduled) }
        do {
            try await transport.waitForFirstCall()
        } catch {
            first.cancel()
            await transport.releaseFirstCall()
            _ = await first.result
            throw error
        }
        await #expect(throws: SchedulePostingError.alreadyInFlight) {
            try await store.postSchedule(review: review, date: .scheduled)
        }
        first.cancel()
        await transport.releaseFirstCall()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await database.pendingLocalSyncMessageCount() == 0)

        let freshReview = try await store.schedulePostingReview(budgetID: "group-1", scheduleID: "rent")
        let retried = try await store.postSchedule(review: freshReview, date: .scheduled)
        #expect(try await database.fetchTransaction(id: retried.transactionID)?.schedule == "rent")
    }

    @Test func sameBudgetSessionChangePreventsOldLeaseReleasingNewPost() async throws {
        let bundle = try await makeBundle(transport: RecordingSyncTransport())
        let store = bundle.store
        let gate = store.schedulePostingGate
        let oldGeneration = store.budgetSessionGeneration
        let old = try gate.acquire(
            budgetID: "group-1", scheduleID: "rent", sessionGeneration: oldGeneration
        )
        store.closeOpenBudget()
        let reopened = try gate.acquire(
            budgetID: "group-1", scheduleID: "rent", sessionGeneration: store.budgetSessionGeneration
        )

        gate.release(old)

        #expect(throws: SchedulePostingError.alreadyInFlight) {
            try gate.acquire(
                budgetID: "group-1", scheduleID: "rent", sessionGeneration: store.budgetSessionGeneration
            )
        }
        gate.release(reopened)
    }

    @Test func supersededRefreshReturnsDurableReceiptMarkedRefreshPending() async throws {
        let transport = RecordingSyncTransport()
        let bundle = try await makeBundle(transport: transport)
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let store = bundle.store
        let database = try #require(store.database)
        let review = try await store.schedulePostingReview(budgetID: "group-1", scheduleID: "rent")
        store.scheduleReadHook = { _, _ in store.closeOpenBudget() }
        defer { store.scheduleReadHook = nil }

        let receipt = try await store.postSchedule(review: review, date: .scheduled)

        #expect(receipt.refreshPending)
        #expect(try await database.fetchTransaction(id: receipt.transactionID)?.schedule == "rent")
        #expect(try await database.pendingLocalSyncMessageCount() > 0)
    }

    @Test func failedPostCommitRefreshClearsOldFeedAndPreservesReceipt() async throws {
        let failure = SchedulePostingRefreshFailure()
        let bundle = try await support.makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() },
            additionalFixtureSQL: Self.scheduleFixtureSQL,
            transactionFeedPageReadHook: { _, _, _, _ in
                if failure.enabled { throw SchedulePostingGateTestError.refreshFailed }
            }
        )
        bundle.store.openedServerURLString = "https://sync.example"
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let store = bundle.store
        let database = try #require(store.database)
        try await store.refreshAccountTransactions(budgetID: "group-1", accountID: "checking")
        #expect(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking") != nil)
        let review = try await store.schedulePostingReview(budgetID: "group-1", scheduleID: "rent")
        let outboxObservation = SchedulePostingOutboxObservation()
        store.scheduleMutationAfterCommitHook = {
            await outboxObservation.capturePendingCount(database: database)
            failure.enabled = true
        }
        defer { store.scheduleMutationAfterCommitHook = nil }

        let receipt = try await store.postSchedule(review: review, date: .scheduled)

        #expect(receipt.refreshPending)
        #expect(try await database.fetchTransaction(id: receipt.transactionID)?.schedule == "rent")
        #expect(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking") == nil)
        #expect((outboxObservation.pendingCount ?? 0) > 0)
    }

    private func makeBundle(
        transport: any ActualSyncTransport,
        fixtureSupport: LocalFirstActualStoreTests? = nil
    ) async throws -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        let bundle = try await (fixtureSupport ?? support).makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in transport },
            additionalFixtureSQL: Self.scheduleFixtureSQL
        )
        bundle.store.openedServerURLString = "https://sync.example"
        return bundle
    }

    private static func today() -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return ActualScheduleRecurrence.dayID(from: Date(), calendar: calendar)
    }

    private static var packedToday: Int { Int(today().replacingOccurrences(of: "-", with: ""))! }

    private static var scheduleFixtureSQL: String {
        let day = today().replacingOccurrences(of: "-", with: "")
        return """
            ALTER TABLE transactions ADD COLUMN schedule TEXT;
            CREATE TABLE rules (
                id TEXT PRIMARY KEY, stage TEXT, conditions TEXT, actions TEXT,
                conditions_op TEXT DEFAULT 'and', tombstone INTEGER DEFAULT 0
            );
            CREATE TABLE schedules (
                id TEXT PRIMARY KEY, rule TEXT, name TEXT, completed INTEGER DEFAULT 0,
                posts_transaction INTEGER DEFAULT 0, custom_upcoming_length TEXT,
                sort_order REAL, tombstone INTEGER DEFAULT 0
            );
            CREATE TABLE schedules_next_date (
                id TEXT PRIMARY KEY, schedule_id TEXT, local_next_date INTEGER,
                local_next_date_ts INTEGER, base_next_date INTEGER, base_next_date_ts INTEGER,
                tombstone INTEGER DEFAULT 0
            );
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('upcomingScheduledTransactionLength', '7');
            INSERT INTO rules VALUES (
                'rent-rule', 'normal',
                '[{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":-10000},{"op":"is","field":"date","value":"\(today())"}]',
                '[{"op":"link-schedule","value":"rent"}]', 'and', 0
            );
            INSERT INTO schedules VALUES ('rent', 'rent-rule', 'Rent', 0, 0, NULL, 1, 0);
            INSERT INTO schedules_next_date VALUES ('rent-next', 'rent', \(day), 100, \(day), 100, 0);
            """
    }
}

private actor SchedulePostingResponseTransport: ActualSyncTransport {
    let messages: [ActualSync_MessageEnvelope]

    init(messages: [ActualSync_MessageEnvelope]) {
        self.messages = messages
    }

    func sync(data: Data, token: String) async throws -> Data {
        var response = ActualSync_SyncResponse()
        response.messages = messages
        return try response.serializedData()
    }
}

@MainActor
private final class SchedulePostingOutboxObservation {
    private(set) var pendingCount: Int?

    func capturePendingCount(database: BudgetDatabase) async {
        pendingCount = try? await database.pendingLocalSyncMessageCount()
    }
}

@MainActor
private final class SchedulePostingCommitGate {
    private let entry = TestLatch()
    private let releaseLatch = TestLatch()
    private var entered = false

    var didEnter: Bool { entered }

    func pause() async {
        entered = true
        entry.trip()
        await releaseLatch.wait()
    }

    func waitForEntry(timeout: Duration = .seconds(10)) async throws {
        if entered { return }
        let entry = self.entry
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await entry.wait() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SchedulePostingGateTestError.timedOut
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                entry.trip()
                releaseLatch.trip()
                throw error
            }
        }
    }

    func release() {
        releaseLatch.trip()
    }
}

private enum SchedulePostingGateTestError: Error {
    case timedOut
    case refreshFailed
}

@MainActor
private final class SchedulePostingRefreshFailure {
    var enabled = false
}

private actor GatedSchedulePostingSyncTransport: ActualSyncTransport {
    private let firstCallEntered = TestLatch()
    private let releaseFirst = TestLatch()
    private var callCount = 0

    func sync(data: Data, token: String) async throws -> Data {
        callCount += 1
        if callCount == 1 {
            firstCallEntered.trip()
            await releaseFirst.wait()
        }
        return try ActualSync_SyncResponse().serializedData()
    }

    func waitForFirstCall(timeout: Duration = .seconds(10)) async throws {
        let entered = firstCallEntered
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await entered.wait() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SchedulePostingGateTestError.timedOut
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                firstCallEntered.trip()
                releaseFirst.trip()
                throw error
            }
        }
    }
    func releaseFirstCall() { releaseFirst.trip() }
}
