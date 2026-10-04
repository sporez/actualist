import Foundation
import GRDB
import Testing
@testable import Actualist

/// Phase 2 sync hardening: remote timestamp validation (2.5), quarantine of
/// unreadable values (2.6) and storing superseded messages as old (2.7).
@MainActor
@Suite("Remote sync validation")
struct RemoteSyncValidationTests {
    private let support = LocalFirstActualStoreTests()
    private let t1 = "2026-07-04T12:00:00.000Z-0000-node1"
    private let t2 = "2026-07-04T12:00:01.000Z-0000-node1"
    private let t3 = "2026-07-04T12:00:02.000Z-0000-node1"

    // MARK: 2.5 timestamp validation

    @Test func batchWithAnHourFutureMessageThrowsAppliesNothingAndKeepsSince() async throws {
        let url = try support.makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")
        _ = try await database.applyRemoteSyncMessages([message(t1, "txn", "category", "S:before")])
        let sinceBefore = try await database.latestSyncTimestamp()
        let future = Self.timestamp(offset: 3_600)

        await #expect(throws: LocalFirstError.clockDrift) {
            _ = try await database.applyRemoteSyncMessages([
                message(t2, "txn", "category", "S:good"),
                message(future, "txn", "category", "S:future")
            ])
        }

        #expect(try scalar("SELECT category FROM transactions WHERE id = 'txn'", url) == "before")
        #expect(try scalar("SELECT COUNT(*) FROM messages_crdt", url) == "1")
        #expect(try await database.latestSyncTimestamp() == sinceBefore)
    }

    @Test func messageWithinFiveMinutesOfDriftIsAccepted() async throws {
        let url = try support.makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")
        let near = Self.timestamp(offset: 240)

        #expect(try await database.applyRemoteSyncMessages([message(near, "txn", "category", "S:near")]) == 1)
    }

    @Test(arguments: [
        "not-a-timestamp",
        "2026-07-04T12:00:00.000Z-ZZZZ-node1",
        "2026-07-04T12:00:00.000Z-0000-",
        "2026-13-45T12:00:00.000Z-0000-node1",
        "2026-07-04T12:00:00.000Z-0000-node1-extra",
        "2026-07-04T12:00:00Z-0000-node1",
        "2026-07-04T12:00:00.000Z-+1A0-node1",
        "2026-07-04T12:00:00.000Z-10000-node1",
        "2026-07-04T12:00:00.000Z-0000-0123456789abcdef0"
    ])
    func malformedTimestampThrowsAndAppliesNothing(_ bad: String) async throws {
        let url = try support.makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")

        await #expect(throws: LocalFirstError.invalidSyncTimestamp) {
            _ = try await database.applyRemoteSyncMessages([
                message(t1, "txn", "category", "S:good"),
                message(bad, "txn", "category", "S:bad")
            ])
        }

        #expect(try scalar("SELECT COUNT(*) FROM messages_crdt", url) == "0")
        #expect(try scalar("SELECT category FROM transactions WHERE id = 'txn'", url) == "groceries")
    }

    @Test func sinceIsClampedWhenAStoredRowIsFarInTheFuture() async throws {
        let url = try support.makeSQLiteFixture(extraSQL: """
            INSERT INTO messages_crdt VALUES ('2099-01-01T00:00:00.000Z-0000-node1', 'transactions', 'txn', 'category', 'S:x');
            """)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")
        let ceiling = Self.timestamp(offset: 301)

        let since = try await database.latestSyncTimestamp()

        #expect(since < ceiling)
        #expect(since > Self.timestamp(offset: 240))
    }

    @Test func sinceKeepsAnOrdinaryStoredTimestamp() async throws {
        let url = try support.makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")
        _ = try await database.applyRemoteSyncMessages([message(t1, "txn", "category", "S:a")])

        #expect(try await database.latestSyncTimestamp() == t1)
    }

    @Test func clockObserveIgnoresInvalidTimestamps() {
        var clock = HybridLogicalClock(nodeID: "node1", lastTimestamp: t1)

        clock.observe("garbage")
        clock.observe("2099-13-45T00:00:00.000Z-0000-node1")
        clock.observe("2026-07-04T12:00:09.000Z-GGGG-node1")

        #expect(clock.lastTimestamp == t1)
        clock.observe(t2)
        #expect(clock.lastTimestamp == t2)
    }

    @Test func clockNextThrowsWhenTheLastTimestampIsOverFiveMinutesAhead() throws {
        var clock = HybridLogicalClock(nodeID: "node1", lastTimestamp: Self.timestamp(offset: 3_600, node: "node1"))

        #expect(throws: LocalFirstError.clockDrift) {
            _ = try clock.next(now: Date())
        }
    }

    @Test func clockNextAcceptsAFewMinutesOfDrift() throws {
        var clock = HybridLogicalClock(nodeID: "node1", lastTimestamp: Self.timestamp(offset: 240, node: "node1"))

        let next = try clock.next(now: Date())

        #expect(next.hasSuffix("-0001-node1"))
    }

    // MARK: 2.6 quarantine

    @Test func unreadableValueIsStoredNotAppliedAndDoesNotBlockTheBatch() async throws {
        let url = try support.makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")

        let result = try await database.applyRemoteSyncMessagesTrackingInserts([
            message(t1, "txn", "category", "S:first"),
            message(t2, "txn", "amount", "X:oops"),
            message(t3, "txn", "category", "S:second")
        ])

        #expect(try scalar("SELECT category FROM transactions WHERE id = 'txn'", url) == "second")
        #expect(try scalar("SELECT amount FROM transactions WHERE id = 'txn'", url) == "-12345")
        #expect(try scalar("SELECT COUNT(*) FROM messages_crdt", url) == "3")
        #expect(result.appliedMessageCount == 2)
        #expect(result.quarantinedTimestamps == [t2])
    }

    @Test func nonFiniteAndEmptyValuesAreQuarantined() async throws {
        let url = try support.makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")

        let result = try await database.applyRemoteSyncMessagesTrackingInserts([
            message(t1, "txn", "amount", "N:inf"),
            message(t2, "txn", "amount", "")
        ])

        #expect(result.quarantinedTimestamps == [t1, t2])
        #expect(try scalar("SELECT amount FROM transactions WHERE id = 'txn'", url) == "-12345")
    }

    @Test func localWriteDecodingStillRejectsAnUnreadableValue() async throws {
        let url = try support.makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")

        await #expect(throws: LocalFirstError.invalidSyncValue) {
            _ = try await database.commitLocalSyncMessagesAndEnqueue([message(t1, "txn", "amount", "X:oops")])
        }
        #expect(try scalar("SELECT COUNT(*) FROM messages_crdt", url) == "0")
    }

    @Test func quarantineDiagnosticSurvivesRedactionAndCarriesOnlyCountsAndTimestamps() {
        let text = SafeSyncDiagnostic.quarantineMessage(count: 2, earliest: t1, latest: t3)

        #expect(SafeSyncDiagnostic.eventMessage(text, outcome: .failed) == text)
        #expect(SafeSyncDiagnostic.eventMessage(text, outcome: .succeeded) == text)
        #expect(SafeSyncDiagnostic.eventMessage("Skipped 2 synced values that could not be read (secret).", outcome: .failed)
            == SafeSyncDiagnostic.previousFailure)
    }

    // MARK: 2.7 superseded messages

    @Test func supersededRemoteMessageIsStoredAsOldAndNotApplied() async throws {
        let url = try support.makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")

        #expect(try await database.applyRemoteSyncMessages([message(t2, "txn", "category", "S:t2")]) == 1)
        #expect(try await database.applyRemoteSyncMessages([message(t1, "txn", "category", "S:t1")]) == 0)

        #expect(try scalar("SELECT category FROM transactions WHERE id = 'txn'", url) == "t2")
        #expect(try scalar("SELECT COUNT(*) FROM messages_crdt WHERE row = 'txn' AND column = 'category'", url) == "2")
    }

    @Test func exactDuplicateLeavesOneRow() async throws {
        let url = try support.makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")
        let duplicate = message(t1, "txn", "category", "S:once")

        #expect(try await database.applyRemoteSyncMessages([duplicate, duplicate]) == 1)
        #expect(try await database.applyRemoteSyncMessages([duplicate]) == 0)

        #expect(try scalar("SELECT COUNT(*) FROM messages_crdt WHERE timestamp = '\(t1)'", url) == "1")
    }

    // MARK: 2.7 timestamp index

    @Test func existingBudgetGetsTheTimestampIndexAndReopenIsIdempotent() async throws {
        let url = try support.makeSQLiteFixture()
        #expect(try scalar(Self.indexCount, url) == "0")

        _ = try BudgetDatabase(databaseURL: url, localNodeID: "node")
        _ = try BudgetDatabase(databaseURL: url, localNodeID: "node")

        #expect(try scalar(Self.indexCount, url) == "1")
    }

    @Test func newBudgetSeedHasTheTimestampIndex() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ActualistTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "db.sqlite")

        _ = try BudgetDatabase.makeNewBudgetStarterDatabase(at: url)

        #expect(try scalar(Self.indexCount, url) == "1")
    }

    // MARK: helpers

    private static let indexCount = """
        SELECT COUNT(*) FROM sqlite_master
        WHERE type = 'index' AND tbl_name = 'messages_crdt' AND name = 'actualist_messages_crdt_timestamp'
        """

    /// A valid timestamp `offset` seconds from now.
    private static func timestamp(offset: TimeInterval, node: String = "node1") -> String {
        "\(SyncTimestamp.wallTimeString(for: Date().addingTimeInterval(offset)))-0000-\(node)"
    }

    private func message(_ timestamp: String, _ row: String, _ column: String, _ value: String) -> ActualSyncDecodedMessage {
        ActualSyncDecodedMessage(
            timestamp: timestamp, dataset: "transactions", row: row, column: column, serializedValue: value
        )
    }

    private func scalar(_ sql: String, _ url: URL) throws -> String? {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in try String.fetchOne(db, sql: sql) }
    }
}
