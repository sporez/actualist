import GRDB
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func bankSyncStatusCompatibilityReplaysOncePerFile() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO messages_crdt (timestamp, dataset, row, column, value) VALUES
                ('2026-07-01T12:00:00.000Z-0000-remote', 'accounts', 'checking', 'bank_sync_status', 'S:attention-required');
            """)

        _ = try BudgetDatabase(databaseURL: fixtureURL)
        let queue = try DatabaseQueue(path: fixtureURL.path)
        let migratedStatus = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT bank_sync_status FROM accounts WHERE id = 'checking'"
            )
        }
        #expect(migratedStatus == "attention-required")

        try await queue.write { db in
            try db.execute(
                sql: "UPDATE accounts SET bank_sync_status = 'locally-updated' WHERE id = 'checking'"
            )
        }

        _ = try BudgetDatabase(databaseURL: fixtureURL)
        let reopenedStatus = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT bank_sync_status FROM accounts WHERE id = 'checking'"
            )
        }
        #expect(reopenedStatus == "locally-updated")
    }

    @Test func bankSyncStatusSchemaIsEnsuredAfterReplayMigration() throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            CREATE TABLE actualist_local_migrations (
                name TEXT PRIMARY KEY,
                applied_at TEXT NOT NULL
            );
            INSERT INTO actualist_local_migrations (name, applied_at)
                VALUES ('bank-sync-status-compatibility-v1', '0');
            """)

        _ = try BudgetDatabase(databaseURL: fixtureURL)

        #expect(try sqliteColumns("accounts", at: fixtureURL).contains("bank_sync_status"))
    }
}
