import Foundation
import GRDB
import Testing
@testable import Actualist

/// Server messages must not write Actualist-local or bookkeeping tables.
@MainActor
@Suite("Reserved sync datasets")
struct ReservedSyncDatasetTests {
    private let support = LocalFirstActualStoreTests()

    private static let reservedUpstreamTables: Set<String> = [
        "__meta__", "__migrations__", "kvcache", "kvcache_key", "messages_clock", "messages_crdt"
    ]

    nonisolated private static func upstreamTables() throws -> [String] {
        struct Column: Decodable {}
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/ActualCore26_9_0/NewBudget/starter-schema.json")
        let tables = try JSONDecoder().decode([String: [Column]].self, from: Data(contentsOf: url))
        return tables.keys.sorted()
    }

    /// Every pinned upstream table except the six bookkeeping ones is a sync dataset.
    @Test(arguments: try! ReservedSyncDatasetTests.upstreamTables())
    func upstreamDatasetPolicy(_ table: String) {
        #expect(ActualSyncDatasetPolicy.isReserved(table) == Self.reservedUpstreamTables.contains(table))
    }

    @Test(arguments: ["sqlite_sequence", "actualist_budget_identity", "ACTUALIST_Outbox", "messages_crdt", "kvcache", "__x", "db_version"])
    func reservedNamesAreDeniedCaseInsensitively(_ dataset: String) {
        #expect(ActualSyncDatasetPolicy.isReserved(dataset))
    }

    @Test func remoteMessageCannotWriteTheIdentityTableButIsStored() async throws {
        let url = try support.makeSQLiteFixture(extraSQL: """
            CREATE TABLE actualist_budget_identity (id TEXT PRIMARY KEY, mode TEXT);
            INSERT INTO actualist_budget_identity VALUES ('local', 'tracking');
            CREATE TABLE actualist_action_log (id TEXT PRIMARY KEY, kind TEXT);
            INSERT INTO actualist_action_log VALUES ('a1', 'assign');
            """)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")
        let messages = [
            message("2026-07-04T12:34:56.789Z-0000-server", "actualist_budget_identity", "local", "mode", "budget"),
            message("2026-07-04T12:34:56.790Z-0000-server", "actualist_action_log", "a1", "kind", "gone"),
            message("2026-07-04T12:34:56.791Z-0000-server", "actualist_action_log", "new", "kind", "planted")
        ]

        _ = try await database.applyRemoteSyncMessages(messages)

        #expect(try scalar("SELECT mode FROM actualist_budget_identity WHERE id = 'local'", url) == "tracking")
        #expect(try scalar("SELECT kind FROM actualist_action_log WHERE id = 'a1'", url) == "assign")
        #expect(try scalar("SELECT COUNT(*) FROM actualist_action_log", url) == "1")
        #expect(try scalar("SELECT COUNT(*) FROM messages_crdt WHERE dataset LIKE 'actualist_%'", url) == "3")
    }

    @Test func remoteMessageNamingATableWithoutAnIDColumnDoesNotThrow() async throws {
        let url = try support.makeSQLiteFixture(extraSQL: """
            CREATE TABLE actualist_outbox (timestamp TEXT PRIMARY KEY, row TEXT);
            """)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")
        let hostile = message("2026-07-04T12:34:56.789Z-0000-server", "actualist_outbox", "t", "row", "x")
        let good = message("2026-07-04T12:34:56.790Z-0000-server", "accounts", "acct-new", "name", "Fresh")

        _ = try await database.applyRemoteSyncMessages([hostile, good])

        #expect(try scalar("SELECT COUNT(*) FROM actualist_outbox", url) == "0")
        #expect(try scalar("SELECT name FROM accounts WHERE id = 'acct-new'", url) == "Fresh")
        #expect(try scalar("SELECT COUNT(*) FROM messages_crdt WHERE dataset = 'actualist_outbox'", url) == "1")
    }

    @Test func localWritesToReservedDatasetsAreRejected() async throws {
        let url = try support.makeSQLiteFixture(extraSQL: """
            CREATE TABLE actualist_budget_identity (id TEXT PRIMARY KEY, mode TEXT);
            """)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")
        let local = message("2026-07-04T12:34:56.789Z-0000-local", "actualist_budget_identity", "local", "mode", "x")

        await #expect(throws: LocalFirstError.invalidLocalWrite("unknown dataset actualist_budget_identity")) {
            _ = try await database.applyLocalSyncMessages([local])
        }
        #expect(try scalar("SELECT COUNT(*) FROM actualist_budget_identity WHERE id = 'local'", url) == "0")
    }

    private func message(
        _ timestamp: String, _ dataset: String, _ row: String, _ column: String, _ value: String
    ) -> ActualSyncDecodedMessage {
        ActualSyncDecodedMessage(
            timestamp: timestamp, dataset: dataset, row: row, column: column,
            serializedValue: LocalFirstSyncValue.string(value).serialized
        )
    }

    private func scalar(_ sql: String, _ url: URL) throws -> String? {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in try String.fetchOne(db, sql: sql) }
    }
}
