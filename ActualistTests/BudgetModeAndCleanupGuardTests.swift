import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct BudgetModeAndCleanupGuardTests {
    private let fixtures = LocalFirstActualStoreTests()

    @Test func tombstonedTrackingPreferenceReadsAsEnvelope() async throws {
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT, tombstone INTEGER DEFAULT 0);
            INSERT INTO preferences VALUES ('budgetType', 'tracking', 1);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        #expect(try await database.isTrackingBudget() == false)
    }

    @Test func liveTrackingPreferenceStillReadsAsTracking() async throws {
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT, tombstone INTEGER DEFAULT 0);
            INSERT INTO preferences VALUES ('budgetType', 'tracking', 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        #expect(try await database.isTrackingBudget() == true)
    }

    @Test func emptyCleanupDefinitionDoesNotAbortApplyAndKeepsGroups() async throws {
        let fixtureURL = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN cleanup_def TEXT;
            CREATE TABLE cleanup_groups (id TEXT PRIMARY KEY, name TEXT, tombstone INTEGER);
            INSERT INTO cleanup_groups VALUES ('orphan-group', 'Orphan', 0);
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":10,"priority":0}]',
                cleanup_def = ''
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateApply(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        ).messages
        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)

        #expect(try orphanGroupTombstone(at: fixtureURL) == 0)
    }

    private func orphanGroupTombstone(at url: URL) throws -> Int? {
        try DatabaseQueue(path: url.path).read { db in
            try Int.fetchOne(db, sql: "SELECT tombstone FROM cleanup_groups WHERE id = 'orphan-group'")
        }
    }
}
