import Foundation
import GRDB
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    private func migrationIDs(at url: URL) throws -> [Int64] {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.readSync { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM __migrations__ ORDER BY id")
        }
    }

    private static let bothUpstreamIDs: [Int64] = [1_780_606_215_000, 1_787_013_118_115]

    @Test func compatibilityRecordsUpstreamMigrationIDsOnOpen() throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            CREATE TABLE __migrations__ (id INT PRIMARY KEY NOT NULL);
            INSERT INTO __migrations__ (id) VALUES (1000);
            """)

        _ = try BudgetDatabase(databaseURL: fixtureURL)
        #expect(try migrationIDs(at: fixtureURL) == [1000] + Self.bothUpstreamIDs)

        // A second open neither duplicates nor changes the rows.
        _ = try BudgetDatabase(databaseURL: fixtureURL)
        #expect(try migrationIDs(at: fixtureURL) == [1000] + Self.bothUpstreamIDs)
    }

    @Test func compatibilityBackfillsIDsForFilesItAlreadyChanged() throws {
        // Compat already added both columns and the table, and recorded its
        // earlier markers, but never wrote the upstream ids.
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            CREATE TABLE __migrations__ (id INT PRIMARY KEY NOT NULL);
            ALTER TABLE accounts ADD COLUMN bank_sync_status TEXT;
            ALTER TABLE accounts ADD COLUMN account_group_id TEXT DEFAULT NULL;
            CREATE TABLE account_groups (
                id TEXT PRIMARY KEY, name TEXT, sort_order REAL, tombstone INTEGER DEFAULT 0
            );
            CREATE TABLE actualist_local_migrations (name TEXT PRIMARY KEY, applied_at TEXT NOT NULL);
            INSERT INTO actualist_local_migrations (name, applied_at) VALUES
                ('bank-sync-status-compatibility-v1', '0'),
                ('account-group-compatibility-v1', '0');
            """)

        _ = try BudgetDatabase(databaseURL: fixtureURL)
        #expect(try migrationIDs(at: fixtureURL) == Self.bothUpstreamIDs)
        let queue = try DatabaseQueue(path: fixtureURL.path)
        let marker = try queue.readSync { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM actualist_local_migrations WHERE name = 'compat-migration-ids-v1'"
            )
        }
        #expect(marker == 1)
    }

    @Test func compatibilityLeavesDifferingAccountGroupsUnrecorded() throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            CREATE TABLE __migrations__ (id INT PRIMARY KEY NOT NULL);
            CREATE TABLE account_groups (id TEXT PRIMARY KEY, title TEXT);
            """)

        _ = try BudgetDatabase(databaseURL: fixtureURL)
        #expect(try migrationIDs(at: fixtureURL) == [1_780_606_215_000])
    }

    @Test func compatibilitySkipsFilesWithoutMigrationsTable() throws {
        let fixtureURL = try makeSQLiteFixture()

        _ = try BudgetDatabase(databaseURL: fixtureURL)
        let queue = try DatabaseQueue(path: fixtureURL.path)
        let exists = try queue.readSync { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = '__migrations__')"
            )
        }
        #expect(exists == false)
    }
}
