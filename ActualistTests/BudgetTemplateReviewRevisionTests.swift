import Foundation
import GRDB
import Testing
@testable import Actualist

@Suite("Budget template review revisions")
@MainActor
struct BudgetTemplateReviewRevisionTests {
    private let fixtures = LocalFirstActualStoreTests()

    @Test func singleAndPairedPreviewsCaptureTheSameSQLiteRevision() async throws {
        let url = try templateFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "review-tests")
        _ = try await database.applyRemoteSyncMessages([
            remoteMessage(
                timestamp: "2026-09-20T00:00:00.000Z-0000-0000000000000001",
                row: "remote-row"
            )
        ])

        let single = try await database.previewBudgetTemplate(
            command: .overwrite,
            month: "2026-07"
        )
        let pair = try await database.previewBudgetTemplatePair(month: "2026-07")
        guard case .ready(let fillEmpty) = pair.fillEmpty,
              case .ready(let overwrite) = pair.overwrite else {
            Issue.record("Expected both paired template previews to be ready")
            return
        }

        #expect(single.reviewRevision == overwrite.reviewRevision)
        #expect(fillEmpty.reviewRevision == overwrite.reviewRevision)
        #expect(overwrite.reviewRevision?.messageCount == 1)
        #expect(
            overwrite.reviewRevision?.maxMessageTimestamp
                == "2026-09-20T00:00:00.000Z-0000-0000000000000001"
        )
        #expect(overwrite.reviewRevision?.modeIdentity.storageID.isEmpty == false)
    }

    @Test func staleReviewedAssignmentDoesNotChangeBudgetHistoryOrOutbox() async throws {
        let url = try templateFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "review-tests")
        let preview = try await database.previewBudgetTemplate(
            command: .overwrite,
            month: "2026-07"
        )
        let revision = try #require(preview.reviewRevision)

        let unrelatedLocalWrite = ActualSyncDecodedMessage(
            timestamp: "actualist-pending-unrelated",
            dataset: "categories",
            row: "groceries",
            column: "name",
            serializedValue: "S:Groceries"
        )
        #expect(
            try await database.commitLocalSyncMessagesAndEnqueue([unrelatedLocalWrite]) == 1
        )
        let before = try await sqliteState(at: url)
        var builder = LocalFirstSyncMessageBuilder()
        let apply = try await database.budgetTemplateApply(
            command: .overwrite,
            month: "2026-07",
            builder: &builder
        )
        #expect(!apply.assignments.isEmpty)

        await #expect(throws: LocalFirstError.budgetTemplateReviewStale) {
            _ = try await database.commitUserAction(
                apply.messages,
                descriptor: .template(
                    month: "2026-07",
                    mode: .overwrite,
                    assignments: apply.assignments
                ),
                source: .ui,
                expectedTemplateReviewRevision: revision
            )
        }

        let after = try await sqliteState(at: url)
        #expect(after.budgetedAmount == before.budgetedAmount)
        #expect(after.messageCount == before.messageCount)
        #expect(after.outboxCount == before.outboxCount)
        #expect(after.actionLogCount == before.actionLogCount)
    }

    @Test func olderRemoteMessageInvalidatesEmptyReviewedCommitWithoutWrites() async throws {
        let url = try templateFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "review-tests")
        _ = try await database.applyRemoteSyncMessages([
            remoteMessage(
                timestamp: "2026-09-20T00:00:00.000Z-0000-0000000000000001",
                row: "first-remote-row"
            )
        ])
        let preview = try await database.previewBudgetTemplate(
            command: .fillEmpty,
            month: "2026-07"
        )
        let revision = try #require(preview.reviewRevision)

        _ = try await database.applyRemoteSyncMessages([
            remoteMessage(
                timestamp: "2026-09-19T00:00:00.000Z-0000-0000000000000001",
                row: "older-remote-row"
            )
        ])
        let before = try await sqliteState(at: url)
        await #expect(throws: LocalFirstError.budgetTemplateReviewStale) {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(
                [],
                expectedTemplateReviewRevision: revision
            )
        }
        let after = try await sqliteState(at: url)
        #expect(after.budgetedAmount == before.budgetedAmount)
        #expect(after.messageCount == before.messageCount)
        #expect(after.outboxCount == before.outboxCount)
        #expect(after.actionLogCount == before.actionLogCount)
    }

    @Test func goalOnlyReviewedCommitUsesTheGuardWithoutHistory() async throws {
        let url = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            ALTER TABLE zero_budgets ADD COLUMN goal INTEGER;
            ALTER TABLE zero_budgets ADD COLUMN long_goal INTEGER;
            UPDATE categories SET goal_def =
                '[{"directive":"goal","type":"goal","amount":600,"priority":null}]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "review-tests")
        let preview = try await database.previewBudgetTemplate(
            command: .overwrite,
            month: "2026-07"
        )
        let revision = try #require(preview.reviewRevision)
        var builder = LocalFirstSyncMessageBuilder()
        let apply = try await database.budgetTemplateApply(
            command: .overwrite,
            month: "2026-07",
            builder: &builder
        )
        #expect(apply.assignments.isEmpty)
        #expect(!apply.messages.isEmpty)

        _ = try await database.applyRemoteSyncMessages([
            remoteMessage(
                timestamp: "2026-09-19T00:00:00.000Z-0000-0000000000000001",
                row: "goal-only-race"
            )
        ])
        await #expect(throws: LocalFirstError.budgetTemplateReviewStale) {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(
                apply.messages,
                expectedTemplateReviewRevision: revision
            )
        }
        let state = try await sqliteState(at: url)
        #expect(state.goal == nil)
        #expect(state.outboxCount == 0)
        #expect(state.actionLogCount == 0)
    }

    @Test func unchangedReviewedRevisionPersistsProjectedAssignment() async throws {
        let url = try templateFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "review-tests")
        let preview = try await database.previewBudgetTemplate(
            command: .overwrite,
            month: "2026-07"
        )
        let revision = try #require(preview.reviewRevision)
        let projected = try #require(
            preview.categories.first { $0.categoryID == "groceries" }?.proposed
        )
        var builder = LocalFirstSyncMessageBuilder()
        let apply = try await database.budgetTemplateApply(
            command: .overwrite,
            month: "2026-07",
            builder: &builder
        )
        #expect(try await database.commitUserAction(
            apply.messages,
            descriptor: .template(
                month: "2026-07",
                mode: .overwrite,
                assignments: apply.assignments
            ),
            source: .ui,
            expectedTemplateReviewRevision: revision
        ) == apply.messages.count)

        let state = try await sqliteState(at: url)
        #expect(state.budgetedAmount == projected)
        #expect(state.outboxCount == apply.messages.count)
        #expect(state.actionLogCount == 1)
    }

    @Test func deletingPendingOutboxRowsDoesNotInvalidateReviewedRevision() async throws {
        let url = try templateFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "review-tests")
        _ = try await database.commitLocalSyncMessagesAndEnqueue([
            ActualSyncDecodedMessage(
                timestamp: "actualist-pending-before-review",
                dataset: "categories",
                row: "groceries",
                column: "name",
                serializedValue: "S:Groceries"
            )
        ])
        let preview = try await database.previewBudgetTemplate(
            command: .overwrite,
            month: "2026-07"
        )
        let revision = try #require(preview.reviewRevision)
        try await database.deletePendingLocalSyncMessages(try await database.pendingLocalSyncMessages())

        var builder = LocalFirstSyncMessageBuilder()
        let apply = try await database.budgetTemplateApply(
            command: .overwrite,
            month: "2026-07",
            builder: &builder
        )
        #expect(
            try await database.commitUserAction(
                apply.messages,
                descriptor: .template(
                    month: "2026-07",
                    mode: .overwrite,
                    assignments: apply.assignments
                ),
                source: .ui,
                expectedTemplateReviewRevision: revision
            ) == apply.messages.count
        )
    }

    @Test func storeReviewedApplyReusesTheExistingTemplateMutationPath() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let preview = try await bundle.store.previewBudgetTemplate(
            command: .category("groceries"),
            budgetID: "group-1",
            month: "2026-07"
        )
        let revision = try #require(preview.reviewRevision)
        let expectedAmount = try #require(
            preview.categories.first { $0.categoryID == "groceries" }?.proposed
        )
        let loaded = try await bundle.store.applyReviewedBudgetTemplateAndRefresh(
            reviewRevision: revision,
            command: .category("groceries"),
            budgetID: "group-1",
            month: "2026-07",
            didApply: {}
        )
        let groceries = try #require(
            loaded.month.categoryGroups
                .flatMap(\.categories)
                .first { $0.id == "groceries" }
        )
        #expect(groceries.budgeted == expectedAmount)
        #expect(try await bundle.store.recentBudgetActions(budgetID: "group-1").count == 1)
    }

    @Test func replacingImportedStorageIdentityInvalidatesReviewedRevision() async throws {
        let url = try templateFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "review-tests")
        let preview = try await database.previewBudgetTemplate(
            command: .fillEmpty,
            month: "2026-07"
        )
        let revision = try #require(preview.reviewRevision)
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE actualist_budget_identity SET storage_id = ? WHERE id = 1",
                arguments: [UUID().uuidString]
            )
        }

        await #expect(throws: LocalFirstError.budgetTemplateReviewStale) {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(
                [],
                expectedTemplateReviewRevision: revision
            )
        }
    }

    private func templateFixture() throws -> URL {
        try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            ALTER TABLE categories ADD COLUMN template_settings TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":20,"priority":1}]',
                template_settings = '{"source":"ui"}'
            WHERE id = 'groceries';
            """)
    }

    private func remoteMessage(timestamp: String, row: String) -> ActualSyncDecodedMessage {
        ActualSyncDecodedMessage(
            timestamp: timestamp,
            dataset: "categories",
            row: row,
            column: "name",
            serializedValue: "S:Remote"
        )
    }

    private struct SQLiteState {
        let budgetedAmount: Int?
        let goal: Int?
        let messageCount: Int
        let outboxCount: Int
        let actionLogCount: Int
    }

    private func sqliteState(at url: URL) async throws -> SQLiteState {
        let queue = try DatabaseQueue(path: url.path)
        return try await queue.read { db in
            let outboxCount = try countRows(in: "actualist_outbox", db: db)
            let actionLogCount = try countRows(in: "actualist_action_log", db: db)
            let budgetColumns = Set(
                try Row.fetchAll(db, sql: "PRAGMA table_info(zero_budgets)")
                    .compactMap { $0["name"] as String? }
            )
            return SQLiteState(
                budgetedAmount: try Int.fetchOne(
                    db,
                    sql: "SELECT amount FROM zero_budgets WHERE month = 202607 AND category = 'groceries'"
                ),
                goal: budgetColumns.contains("goal")
                    ? try Int.fetchOne(
                        db,
                        sql: "SELECT goal FROM zero_budgets WHERE month = 202607 AND category = 'groceries'"
                    )
                    : nil,
                messageCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0,
                outboxCount: outboxCount,
                actionLogCount: actionLogCount
            )
        }
    }

    nonisolated private func countRows(in table: String, db: Database) throws -> Int {
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            arguments: [table]
        ) == true else {
            return 0
        }
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }
}
