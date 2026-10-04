import Foundation
import GRDB
import Testing
@testable import Actualist

/// Small session/reload/key hygiene regressions from the audit's Phase 2 lane A.
extension LocalFirstActualStoreTests {
    @Test func staleDatabaseCannotOverwriteTheActionLogDiagnosticSnapshot() async throws {
        let store = try await makeOpenedWritableStore()
        let current = ActionLogDiagnosticSnapshot(count: 5, newestCreatedAt: Date(timeIntervalSince1970: 1_000))
        store.actionLogDiagnosticSnapshot = current
        let staleDatabase = try BudgetDatabase(databaseURL: makeSQLiteFixture(), localNodeID: "stale-node")

        await store.refreshActionLogDiagnosticSnapshot(database: staleDatabase)

        #expect(store.actionLogDiagnosticSnapshot == current)
    }

    @Test func pullWithoutAConfiguredSessionThrowsInsteadOfReportingSuccess() async throws {
        let database = try BudgetDatabase(databaseURL: makeSQLiteFixture(), localNodeID: "node")
        let client = SyncClient()

        await #expect(throws: LocalFirstError.budgetNotOpened) {
            _ = try await client.pullAndApply(
                database: database,
                client: FixedResponseSyncTransport(responseData: Data()),
                token: "token"
            )
        }
    }

    @Test func undoReloadsTheBudgetCachesOnce() async throws {
        let store = try await makeOpenedWritableStore()
        _ = try await store.assignCategoryBudgetAndRefresh(expectedMode: nil,
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let row = try #require(try await store.recentBudgetActions(budgetID: "group-1").first)
        let readGenerationBefore = store.budgetReadGeneration

        try await store.undoBudgetActionAndRefresh(actionID: row.id, budgetID: "group-1")

        // `reloadSelectedBudgetCache` advances `budgetReadGeneration` once per reload.
        #expect(store.budgetReadGeneration == readGenerationBefore &+ 1)
    }

    @Test func remoteRowsWhoseDatasetAndRowConcatenateIdenticallyBothInsert() async throws {
        let url = try makeSQLiteFixture(extraSQL: Self.collidingTablesSQL)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")

        _ = try await database.applyRemoteSyncMessages(Self.collidingMessages())

        #expect(try collidingRowCounts(url) == [1, 1])
    }

    @Test func localRowsWhoseDatasetAndRowConcatenateIdenticallyBothInsert() async throws {
        let url = try makeSQLiteFixture(extraSQL: Self.collidingTablesSQL)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")

        _ = try await database.applyLocalSyncMessages(Self.collidingMessages())

        #expect(try collidingRowCounts(url) == [1, 1])
    }

    private static let collidingTablesSQL = """
        CREATE TABLE a (id TEXT PRIMARY KEY, x TEXT);
        CREATE TABLE ab (id TEXT PRIMARY KEY, x TEXT);
        """

    /// ("ab", "c") and ("a", "bc") concatenate to the same "abc".
    private static func collidingMessages() -> [ActualSyncDecodedMessage] {
        [
            ActualSyncDecodedMessage(
                timestamp: "2026-07-04T12:34:56.789Z-0000-0123456789abcdef",
                dataset: "ab", row: "c", column: "x",
                serializedValue: LocalFirstSyncValue.string("first").serialized
            ),
            ActualSyncDecodedMessage(
                timestamp: "2026-07-04T12:34:56.790Z-0000-0123456789abcdef",
                dataset: "a", row: "bc", column: "x",
                serializedValue: LocalFirstSyncValue.string("second").serialized
            )
        ]
    }

    private func collidingRowCounts(_ url: URL) throws -> [Int] {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            [
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ab WHERE id = 'c'") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM a WHERE id = 'bc'") ?? -1
            ]
        }
    }
}
