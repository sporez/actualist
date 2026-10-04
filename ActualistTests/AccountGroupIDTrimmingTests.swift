import Foundation
import Testing
@testable import Actualist

@MainActor
struct AccountGroupIDTrimmingTests {
    private let fixtures = LocalFirstActualStoreTests()

    private func makeDatabase(groupTableSQL: String) throws -> BudgetDatabase {
        try BudgetDatabase(
            databaseURL: try fixtures.makeSQLiteFixture(extraSQL: """
                CREATE TABLE IF NOT EXISTS __migrations__ (id INTEGER PRIMARY KEY);
                INSERT INTO __migrations__ (id) VALUES (1787013118115);
                \(groupTableSQL)
                """),
            localNodeID: "node1"
        )
    }

    private let standardGroups = """
        CREATE TABLE account_groups (
            id TEXT PRIMARY KEY, name TEXT, sort_order REAL, tombstone INTEGER DEFAULT 0
        );
        INSERT INTO account_groups VALUES ('cash', 'Cash', 16384, 0);
        """

    @Test func renameAndDeleteResolveAWhitespacePaddedGroupID() async throws {
        let database = try makeDatabase(groupTableSQL: standardGroups)
        var builder = LocalFirstSyncMessageBuilder()

        let renamed = try await database.renameAccountGroupMessages(
            groupID: "  cash \n", name: "Wallet", builder: &builder
        )
        #expect(renamed.map(\.row) == ["cash"])
        #expect(renamed.map(\.column) == ["name"])

        let deleted = try await database.deleteAccountGroupMessages(
            groupID: " cash ", builder: &builder
        )
        let tombstone = try #require(deleted.first { $0.column == "tombstone" })
        #expect(tombstone.row == "cash")
    }

    @Test func deleteThrowsWhenTheTombstoneColumnIsMissing() async throws {
        let database = try makeDatabase(groupTableSQL: """
            CREATE TABLE account_groups (id TEXT PRIMARY KEY, name TEXT, sort_order REAL);
            INSERT INTO account_groups VALUES ('cash', 'Cash', 16384);
            """)
        var builder = LocalFirstSyncMessageBuilder()

        await #expect(
            throws: LocalFirstError.invalidLocalWrite("missing column account_groups.tombstone")
        ) {
            _ = try await database.deleteAccountGroupMessages(groupID: "cash", builder: &builder)
        }
    }
}
