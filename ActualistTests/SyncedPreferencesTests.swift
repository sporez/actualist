import Foundation
import GRDB
import Testing
@testable import Actualist

struct SyncedPreferencesTests {
    private func makeDatabase(sql: String) throws -> BudgetDatabase {
        let url = FileManager.default.temporaryDirectory.appending(path: "SyncedPreferences-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in try db.execute(sql: sql) }
        return try BudgetDatabase(databaseURL: url)
    }

    private func read<T: Sendable>(
        _ database: isolated BudgetDatabase,
        _ body: @Sendable (isolated BudgetDatabase, Database) throws -> T
    ) throws -> T {
        try database.queue.read { db in try body(database, db) }
    }

    private func availability(_ database: BudgetDatabase) async throws -> SyncedPreferences.Availability {
        try await read(database) { (database: isolated BudgetDatabase, db: Database) in
            try SyncedPreferences.availability(in: database, db: db)
        }
    }

    private let plainTable = "CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);"
    private let tombstoneTable = "CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT, tombstone INTEGER);"

    @Test func availabilityReflectsTableAndColumns() async throws {
        let none = try makeDatabase(sql: "CREATE TABLE other (id TEXT);")
        let noValue = try makeDatabase(sql: "CREATE TABLE preferences (id TEXT PRIMARY KEY);")
        let noID = try makeDatabase(sql: "CREATE TABLE preferences (value TEXT);")
        let plain = try makeDatabase(sql: plainTable)
        let tombstone = try makeDatabase(sql: tombstoneTable)
        for database in [none, noValue, noID] {
            let result = try await availability(database)
            #expect(result == .unavailable)
        }
        let plainResult = try await availability(plain)
        let tombstoneResult = try await availability(tombstone)
        #expect(plainResult == .available(hasTombstone: false))
        #expect(tombstoneResult == .available(hasTombstone: true))
    }

    @Test func valueReadsLiveRowsOnly() async throws {
        let database = try makeDatabase(sql: tombstoneTable + """
            INSERT INTO preferences VALUES ('a', 'x', 0), ('b', 'gone', 1), ('c', NULL, NULL),
                                           ('d', '', NULL), ('e', 'kept', NULL);
            """)
        let results = try await read(database) { (database: isolated BudgetDatabase, db: Database) in
            var found: [String?] = []
            for id in ["a", "b", "c", "d", "e", "missing"] {
                found.append(try SyncedPreferences.value(SyncedPreferenceKey(id), in: database, db: db))
            }
            return found
        }
        #expect(results == ["x", nil, nil, "", "kept", nil])
    }

    @Test func valueIsNilWhenUnavailableAndValuesOmitsAbsentKeys() async throws {
        let none = try makeDatabase(sql: "CREATE TABLE other (id TEXT);")
        let missing = try await read(none) { (database: isolated BudgetDatabase, db: Database) in
            try SyncedPreferences.value(.budgetType, in: database, db: db)
        }
        #expect(missing == nil)
        let database = try makeDatabase(sql: plainTable + "INSERT INTO preferences VALUES ('hideFraction', 'true');")
        let values = try await read(database) { (database: isolated BudgetDatabase, db: Database) in
            try SyncedPreferences.values([.hideFraction, .defaultCurrencyCode], in: database, db: db)
        }
        #expect(values == ["hideFraction": "true"])
        #expect(SyncedPreferenceKey.showBalances(accountID: "acct").id == "show-balances-acct")
    }

    private func set(
        _ database: BudgetDatabase,
        _ value: String
    ) async throws -> SyncedPreferences.SetResult {
        try await read(database) { (database: isolated BudgetDatabase, db: Database) in
            var builder = LocalFirstSyncMessageBuilder()
            return try SyncedPreferences.setMessages(.learnCategories, to: value, builder: &builder, in: database, db: db)
        }
    }

    private func cells(_ result: SyncedPreferences.SetResult) -> [String] {
        result.messages.map { "\($0.dataset).\($0.row).\($0.column)" }
    }

    @Test func setMessagesForNewRowAddsTombstoneOnlyWhenColumnExists() async throws {
        let plain = try await set(makeDatabase(sql: plainTable), "false")
        #expect(cells(plain) == ["preferences.learn-categories.value"])
        #expect(plain.previousValue == nil)
        let withTombstone = try await set(makeDatabase(sql: tombstoneTable), "false")
        #expect(cells(withTombstone) == ["preferences.learn-categories.value", "preferences.learn-categories.tombstone"])
        #expect(withTombstone.previousValue == nil)
    }

    @Test func setMessagesForExistingRowWritesValueOnlyAndReportsPrevious() async throws {
        let database = try makeDatabase(sql: tombstoneTable + "INSERT INTO preferences VALUES ('learn-categories', 'true', 0);")
        let result = try await set(database, "false")
        #expect(cells(result) == ["preferences.learn-categories.value"])
        #expect(result.previousValue == "true")
    }

    @Test func setMessagesIsEmptyWhenUnchanged() async throws {
        let database = try makeDatabase(sql: plainTable + "INSERT INTO preferences VALUES ('learn-categories', 'false');")
        let result = try await set(database, "false")
        #expect(result.messages.isEmpty)
        #expect(result.previousValue == "false")
    }

    @Test func setMessagesTreatsTombstonedRowAsNew() async throws {
        let database = try makeDatabase(sql: tombstoneTable + "INSERT INTO preferences VALUES ('learn-categories', 'false', 1);")
        let result = try await set(database, "false")
        #expect(cells(result).count == 2)
        #expect(result.previousValue == nil)
    }

    @Test func setMessagesThrowsWhenUnavailable() async throws {
        let none = try makeDatabase(sql: "CREATE TABLE other (id TEXT);")
        await #expect(throws: LocalFirstError.self) { try await set(none, "true") }
        let noValue = try makeDatabase(sql: "CREATE TABLE preferences (id TEXT PRIMARY KEY);")
        await #expect(throws: LocalFirstError.self) { try await set(noValue, "true") }
    }
}
