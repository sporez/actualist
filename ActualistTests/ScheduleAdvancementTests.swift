import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
@Suite("Schedule advancement")
struct ScheduleAdvancementTests {
    private let support = LocalFirstActualStoreTests()
    private static let today = "2026-09-30"
    private static let missedDay = "2026-01-15"
    private static let budgetID = "budget"

    @Test func dayMarkerPreservesUnknownMetadataKey() async throws {
        let metadata: [String: Any] = [
            "cloudFileId": "file-1",
            "budgetName": "Budget",
            "note": "retain-me",
            "vendorExtension": ["keep": true, "count": 3]
        ]
        let fixture = try makeDatabase(metadata: metadata)

        _ = try await fixture.database.advanceSchedules(budgetID: Self.budgetID, today: Self.today)

        let object = try metadataObject(beside: fixture.url)
        #expect(object["cloudFileId"] as? String == "file-1")
        #expect(object["budgetName"] as? String == "Budget")
        #expect(object["note"] as? String == "retain-me")
        #expect(object["lastScheduleRun"] as? String == Self.today)
        let vendorExtension = try #require(object["vendorExtension"] as? [String: Any])
        #expect(vendorExtension["keep"] as? Bool == true)
        #expect(jsonInt(vendorExtension["count"]) == 3)
    }

    @Test func markerEqualToTodaySkipsDueSchedule() async throws {
        let metadata: [String: Any] = [
            "cloudFileId": "file-1",
            "note": "retain-me",
            "lastScheduleRun": Self.today,
            "vendorExtension": ["keep": true]
        ]
        let fixture = try makeDatabase(
            extraSQL: oneTimeScheduleSQL(scheduleID: "rent", dayID: Self.today, amount: -10_000),
            metadata: metadata
        )
        let before = try Data(contentsOf: metadataURL(beside: fixture.url))

        _ = try await fixture.database.advanceSchedules(budgetID: Self.budgetID, today: Self.today)

        #expect(try Data(contentsOf: metadataURL(beside: fixture.url)) == before)
        #expect(try scheduleTransactionCount("rent", fixture.url) == 0)
        #expect(try await fixture.database.fetchSchedules(budgetID: Self.budgetID, today: Self.today)
            .detail(id: "rent")?.status == .due)
    }

    @Test func dueAutomaticSchedulePostsOnceAndSkipsAfterMarker() async throws {
        let fixture = try makeDatabase(
            extraSQL: oneTimeScheduleSQL(scheduleID: "rent", dayID: Self.today, amount: -10_000),
            metadata: ["cloudFileId": "file-1", "note": "retain-me"]
        )

        _ = try await fixture.database.advanceSchedules(budgetID: Self.budgetID, today: Self.today)
        _ = try await fixture.database.advanceSchedules(budgetID: Self.budgetID, today: Self.today)

        #expect(try scheduleTransactionCount("rent", fixture.url) == 1)
        #expect(try readInt(
            "SELECT date FROM transactions WHERE schedule = 'rent'",
            fixture.url
        ) == Self.packed(Self.today))
        #expect(try readInt(
            "SELECT amount FROM transactions WHERE schedule = 'rent'",
            fixture.url
        ) == -10_000)
        #expect(try readInt(
            "SELECT cleared FROM transactions WHERE schedule = 'rent'",
            fixture.url
        ) == 0)
        let object = try metadataObject(beside: fixture.url)
        #expect(object["lastScheduleRun"] as? String == Self.today)
        #expect(object["note"] as? String == "retain-me")
        #expect(object["cloudFileId"] as? String == "file-1")
        #expect(try await fixture.database.fetchSchedules(budgetID: Self.budgetID, today: Self.today)
            .detail(id: "rent")?.status == .paid)
    }

    @Test func missedRecurringPostsOldDateThenAdvances() async throws {
        let recurrence = try ActualScheduleRecurrence(startDayID: Self.missedDay, frequency: .yearly)
        let expectedNext = try recurrence.nextOccurrence(onOrAfter: "2026-01-16")
        let fixture = try makeDatabase(
            extraSQL: recurringScheduleSQL(
                scheduleID: "rent",
                startDayID: Self.missedDay,
                frequency: "yearly",
                nextDayID: Self.missedDay,
                amount: -10_000
            ),
            metadata: ["note": "retain-me"]
        )

        _ = try await fixture.database.advanceSchedules(budgetID: Self.budgetID, today: Self.today)

        #expect(expectedNext == "2027-01-15")
        #expect(try scheduleTransactionCount("rent", fixture.url) == 1)
        #expect(try readInt(
            "SELECT date FROM transactions WHERE schedule = 'rent'",
            fixture.url
        ) == Self.packed(Self.missedDay))
        let detail = try #require(
            try await fixture.database.fetchSchedules(budgetID: Self.budgetID, today: Self.today).detail(id: "rent")
        )
        #expect(detail.effectiveNextDate == expectedNext)
        #expect(detail.status == .scheduled)
        #expect(try metadataObject(beside: fixture.url)["lastScheduleRun"] as? String == Self.today)
        #expect(try metadataObject(beside: fixture.url)["note"] as? String == "retain-me")
    }

    @Test func closedAccountIsNotPosted() async throws {
        let fixture = try makeDatabase(
            extraSQL: oneTimeScheduleSQL(scheduleID: "rent", dayID: Self.today, amount: -10_000) + """
            UPDATE accounts SET closed = 1 WHERE id = 'checking';
            """,
            metadata: ["note": "retain-me"]
        )

        _ = try await fixture.database.advanceSchedules(budgetID: Self.budgetID, today: Self.today)

        #expect(try scheduleTransactionCount("rent", fixture.url) == 0)
        #expect(try metadataObject(beside: fixture.url)["lastScheduleRun"] as? String == Self.today)
        #expect(try metadataObject(beside: fixture.url)["note"] as? String == "retain-me")
        #expect(try await fixture.database.fetchSchedules(budgetID: Self.budgetID, today: Self.today)
            .detail(id: "rent")?.account.availability == .closed)
    }

    /// The old behavior stopped the whole run at `rent` (delete rule), so
    /// `utilities` never posted and the marker stayed unset on every sync.
    @Test func refusedPostSkipsOnlyThatScheduleAndStillMarksTheDay() async throws {
        let deletingActions = #"[{"op":"link-schedule","value":"rent"},{"op":"delete-transaction","value":""}]"#
        let fixture = try makeDatabase(
            extraSQL: oneTimeScheduleSQL(
                scheduleID: "rent",
                dayID: Self.today,
                amount: -10_000,
                actionsJSON: deletingActions
            ) + oneTimeScheduleSQL(
                scheduleID: "utilities",
                dayID: Self.today,
                amount: -2_000,
                includeSchema: false
            ),
            metadata: ["note": "retain-me", "vendorExtension": ["keep": true]]
        )

        let result = try await fixture.database.advanceSchedules(budgetID: Self.budgetID, today: Self.today)

        #expect(try scheduleTransactionCount("rent", fixture.url) == 0)
        #expect(try scheduleTransactionCount("utilities", fixture.url) == 1)
        #expect(result.receipts.map(\.scheduleID) == ["utilities"])
        #expect(result.refusals == [ScheduleAutoPostRefusal(
            scheduleID: "rent", scheduleName: "rent", refusal: .ruleDeletesTransaction
        )])
        let object = try metadataObject(beside: fixture.url)
        #expect(object["lastScheduleRun"] as? String == Self.today)
        #expect(object["note"] as? String == "retain-me")
        let vendorExtension = try #require(object["vendorExtension"] as? [String: Any])
        #expect(vendorExtension["keep"] as? Bool == true)
    }

    @Test func nonRefusalErrorStopsTheRunAndLeavesTheMarkerUnset() async throws {
        let fixture = try makeDatabase(
            extraSQL: oneTimeScheduleSQL(scheduleID: "rent", dayID: Self.today, amount: -10_000)
                + oneTimeScheduleSQL(scheduleID: "utilities", dayID: Self.today, amount: -2_000, includeSchema: false)
                + "DROP TABLE messages_crdt;",
            metadata: ["note": "retain-me"]
        )

        _ = try await fixture.database.advanceSchedules(budgetID: Self.budgetID, today: Self.today)

        #expect(try scheduleTransactionCount("rent", fixture.url) == 0)
        #expect(try scheduleTransactionCount("utilities", fixture.url) == 0)
        #expect(try metadataObject(beside: fixture.url)["lastScheduleRun"] == nil)
    }

    @Test func autoPostDoesNotWriteAnUnresolvedPayeeMappingID() async throws {
        let conditions = """
        [{"op":"is","field":"account","value":"checking"},{"op":"is","field":"description","value":"ghost-mapping"},{"op":"is","field":"amount","value":-10000},{"op":"is","field":"date","value":"\(Self.today)"}]
        """
        let fixture = try makeDatabase(
            extraSQL: Self.schemaSQL + scheduleInsertSQL(
                scheduleID: "rent",
                conditions: conditions,
                actions: "[{\"op\":\"link-schedule\",\"value\":\"rent\"}]",
                nextDayID: Self.today
            ),
            metadata: ["note": "retain-me"]
        )

        _ = try await fixture.database.advanceSchedules(budgetID: Self.budgetID, today: Self.today)

        #expect(try scheduleTransactionCount("rent", fixture.url) == 1)
        let queue = try DatabaseQueue(path: fixture.url.path)
        let description = try queue.readSync { db in
            try String.fetchOne(db, sql: "SELECT description FROM transactions WHERE schedule = 'rent'")
        }
        #expect(description == nil)
    }

    @Test func storeAdvancesOpenSessionAndIgnoresStaleGeneration() async throws {
        let bundle = try await support.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: Self.storeScheduleSQL
        )
        let store = bundle.store
        store.openedServerURLString = nil
        let database = try #require(store.database)
        let metadataURL = try bundle.fileManager.metadataURL(fileID: "file-1")
        var metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        metadata["vendorExtension"] = ["keep": true]
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL, options: .atomic)
        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")

        await store.advanceSchedulesAfterSuccessfulSync(
            budgetID: "group-1",
            database: database,
            generation: store.budgetSessionGeneration + 1
        )
        await store.advanceSchedulesAfterSuccessfulSync(
            budgetID: "other-budget",
            database: database,
            generation: store.budgetSessionGeneration
        )

        #expect(try scheduleTransactionCount("rent", databaseURL) == 0)
        #expect(try metadataObject(at: metadataURL)["lastScheduleRun"] == nil)
        #expect(store.cachedSchedules(budgetID: "group-1") == nil)

        await store.advanceSchedulesAfterSuccessfulSync(
            budgetID: "group-1",
            database: database,
            generation: store.budgetSessionGeneration
        )
        await store.advanceSchedulesAfterSuccessfulSync(
            budgetID: "group-1",
            database: database,
            generation: store.budgetSessionGeneration
        )

        #expect(try scheduleTransactionCount("rent", databaseURL) == 1)
        #expect(try readInt(
            "SELECT date FROM transactions WHERE schedule = 'rent'",
            databaseURL
        ) == Self.packed(Self.localToday()))
        let patched = try metadataObject(at: metadataURL)
        #expect(patched["lastScheduleRun"] as? String == Self.localToday())
        #expect(patched["budgetName"] as? String == "Writable Budget")
        let vendorExtension = try #require(patched["vendorExtension"] as? [String: Any])
        #expect(vendorExtension["keep"] as? Bool == true)
        #expect(store.cachedSchedules(budgetID: "group-1")?.detail(id: "rent")?.status == .paid)
        #expect(store.openedServerURLString == nil)
    }

    private func makeDatabase(
        extraSQL: String = "",
        metadata: [String: Any]? = nil
    ) throws -> (url: URL, database: BudgetDatabase) {
        let url = try support.makeSQLiteFixture(extraSQL: extraSQL)
        if let metadata {
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: metadataURL(beside: url), options: .atomic)
        }
        return (url, try BudgetDatabase(databaseURL: url, localNodeID: "schedule-advance-node"))
    }

    private func metadataURL(beside databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appending(path: "metadata.json")
    }

    private func metadataObject(beside databaseURL: URL) throws -> [String: Any] {
        try metadataObject(at: metadataURL(beside: databaseURL))
    }

    private func metadataObject(at url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func scheduleTransactionCount(_ scheduleID: String, _ url: URL) throws -> Int {
        try readInt("SELECT COUNT(*) FROM transactions WHERE schedule = '\(scheduleID)'", url)
    }

    private func readInt(_ sql: String, _ url: URL) throws -> Int {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.readSync { db in try Int.fetchOne(db, sql: sql) ?? -1 }
    }

    private func jsonInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func packed(_ dayID: String) -> Int {
        Int(dayID.replacingOccurrences(of: "-", with: ""))!
    }

    private static func localToday() -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return ActualScheduleRecurrence.dayID(from: Date(), calendar: calendar)
    }

    private func oneTimeScheduleSQL(
        scheduleID: String,
        dayID: String,
        amount: Int,
        actionsJSON: String? = nil,
        includeSchema: Bool = true
    ) -> String {
        let actions = actionsJSON ?? "[{\"op\":\"link-schedule\",\"value\":\"\(scheduleID)\"}]"
        let conditions = """
        [{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":\(amount)},{"op":"is","field":"date","value":"\(dayID)"}]
        """
        return (includeSchema ? Self.schemaSQL : "") + scheduleInsertSQL(
            scheduleID: scheduleID,
            conditions: conditions,
            actions: actions,
            nextDayID: dayID
        )
    }

    private func recurringScheduleSQL(
        scheduleID: String,
        startDayID: String,
        frequency: String,
        nextDayID: String,
        amount: Int
    ) -> String {
        let conditions = """
        [{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":\(amount)},{"op":"is","field":"date","value":{"start":"\(startDayID)","frequency":"\(frequency)"}}]
        """
        let actions = "[{\"op\":\"link-schedule\",\"value\":\"\(scheduleID)\"}]"
        return Self.schemaSQL + scheduleInsertSQL(
            scheduleID: scheduleID,
            conditions: conditions,
            actions: actions,
            nextDayID: nextDayID
        )
    }

    private func scheduleInsertSQL(
        scheduleID: String,
        conditions: String,
        actions: String,
        nextDayID: String
    ) -> String {
        let packedDay = Self.packed(nextDayID)
        return """
        INSERT INTO rules VALUES (
            '\(scheduleID)-rule', 'normal',
            '\(conditions)',
            '\(actions)', 'and', 0
        );
        INSERT INTO schedules VALUES ('\(scheduleID)', '\(scheduleID)-rule', '\(scheduleID)', 0, 1, NULL, 1, 0);
        INSERT INTO schedules_next_date VALUES (
            '\(scheduleID)-next', '\(scheduleID)', \(packedDay), 100, \(packedDay), 100, 0
        );
        """
    }

    private static var schemaSQL: String {
        """
        ALTER TABLE transactions ADD COLUMN schedule TEXT;
        ALTER TABLE transactions ADD COLUMN description TEXT;
        ALTER TABLE transactions ADD COLUMN notes TEXT;
        ALTER TABLE transactions ADD COLUMN cleared INTEGER;
        ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
        ALTER TABLE transactions ADD COLUMN isChild INTEGER;
        CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER);
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
        """
    }

    private static var storeScheduleSQL: String {
        let today = localToday()
        let packedDay = Self.packed(today)
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
            '[{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":-10000},{"op":"is","field":"date","value":"\(today)"}]',
            '[{"op":"link-schedule","value":"rent"}]', 'and', 0
        );
        INSERT INTO schedules VALUES ('rent', 'rent-rule', 'Rent', 0, 1, NULL, 1, 0);
        INSERT INTO schedules_next_date VALUES ('rent-next', 'rent', \(packedDay), 100, \(packedDay), 100, 0);
        """
    }
}
