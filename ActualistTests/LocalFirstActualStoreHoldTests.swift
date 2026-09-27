import Foundation
import GRDB
import Synchronization
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func reviewedHoldIsAdditiveClampsToAvailableAndEmitsActualCells() async throws {
        let url = try makeHoldFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "hold-a")

        let initial = try await database.budgetHoldReview(month: "2026-07")
        #expect(initial.toBudget == 150_000)
        #expect(initial.heldAmount == 0)

        try await apply(.hold(amount: 40_000), review: initial, to: database)
        var review = try await database.budgetHoldReview(month: "2026-07")
        #expect(review.toBudget == 110_000)
        #expect(review.manualHeldAmount == 40_000)
        #expect(review.heldAmount == 40_000)

        let firstMessages = try await database.pendingLocalSyncMessages().map(\.message)
        #expect(firstMessages.map(\.dataset) == [
            "zero_budget_months", "zero_budgets", "zero_budgets", "zero_budgets"
        ])
        #expect(firstMessages.map(\.column) == ["buffered", "month", "category", "carryover"])
        #expect(firstMessages.map(\.serializedValue) == ["N:40000", "N:202607", "S:salary", "N:0"])

        try await apply(.hold(amount: 20_000), review: review, to: database)
        review = try await database.budgetHoldReview(month: "2026-07")
        #expect(review.toBudget == 90_000)
        #expect(review.heldAmount == 60_000)

        // Core clamps a positive request to current To Budget.
        try await apply(.hold(amount: 100_000), review: review, to: database)
        review = try await database.budgetHoldReview(month: "2026-07")
        #expect(review.toBudget == 0)
        #expect(review.heldAmount == 150_000)

        let august = try await database.fetchBudgetMonth(month: "2026-08")
        #expect(august.toBudget == 150_000)
        #expect(august.forNextMonth == 0)
    }

    @Test func resetManualHoldRevealsAutomaticHoldThenResetsOnlyItsMonth() async throws {
        let url = try makeHoldFixture(extraSQL: """
            INSERT INTO zero_budget_months VALUES ('2026-07', 20000);
            INSERT INTO zero_budgets VALUES (202607, 'salary', 0, 1);
            INSERT INTO zero_budgets VALUES (202608, 'salary', 0, 1);
            INSERT INTO transactions VALUES ('salary-aug', 'checking', 20260801, 25000, 'salary', 0, NULL, 0);
            """, incomeAmount: 100_000)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "hold-reset")

        var review = try await database.budgetHoldReview(month: "2026-07")
        #expect(review.manualHeldAmount == 20_000)
        #expect(review.automaticHeldAmount == 100_000)
        #expect(review.heldAmount == 20_000)

        try await apply(.reset, review: review, to: database)
        review = try await database.budgetHoldReview(month: "2026-07")
        #expect(review.manualHeldAmount == 0)
        #expect(review.heldAmount == 100_000)
        #expect(review.isAutomaticHold)

        try await apply(.reset, review: review, to: database)
        let july = try await database.budgetHoldReview(month: "2026-07")
        let august = try await database.budgetHoldReview(month: "2026-08")
        #expect(july.heldAmount == 0)
        #expect(august.heldAmount == 25_000)

        let carryoverMessages = try await database.pendingLocalSyncMessages()
            .map(\.message)
            .filter { $0.column == "carryover" }
        #expect(carryoverMessages.count == 1)
        #expect(carryoverMessages.first?.row == "202607-salary")
    }

    @Test func holdRefusesNoAvailabilityAutomaticHoldAndTrackingMode() async throws {
        let unavailableURL = try makeSQLiteFixture(extraSQL: """
            CREATE TABLE zero_budget_months (id TEXT PRIMARY KEY, buffered INTEGER);
            """)
        let unavailable = try BudgetDatabase(databaseURL: unavailableURL, localNodeID: "hold-none")
        let unavailableReview = try await unavailable.budgetHoldReview(month: "2026-07")
        #expect(unavailableReview.toBudget < 0)
        await #expect(throws: LocalFirstError.self) {
            var builder = LocalFirstSyncMessageBuilder()
            _ = try await unavailable.budgetHoldMessages(
                command: .hold(amount: 1), review: unavailableReview, builder: &builder
            )
        }
        #expect(try await unavailable.pendingLocalSyncMessageCount() == 0)
        await #expect(throws: LocalFirstError.self) {
            _ = try await unavailable.budgetHoldReview(month: "2026-7")
        }
        #expect(try await unavailable.budgetHoldReview(month: "2027-01").heldAmount == 0)

        let automaticURL = try makeHoldFixture(extraSQL: """
            INSERT INTO zero_budgets VALUES (202607, 'salary', 0, 1);
            """)
        let automatic = try BudgetDatabase(databaseURL: automaticURL, localNodeID: "hold-auto")
        let automaticReview = try await automatic.budgetHoldReview(month: "2026-07")
        await #expect(throws: LocalFirstError.self) {
            var builder = LocalFirstSyncMessageBuilder()
            _ = try await automatic.budgetHoldMessages(
                command: .hold(amount: 1), review: automaticReview, builder: &builder
            )
        }

        let trackingURL = try makeHoldFixture(extraSQL: """
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('budgetType', 'tracking');
            CREATE TABLE reflect_budgets (
                id TEXT PRIMARY KEY, month INTEGER, category TEXT,
                amount INTEGER, carryover INTEGER
            );
            """)
        let tracking = try BudgetDatabase(databaseURL: trackingURL, localNodeID: "hold-tracking")
        await #expect(throws: BudgetModeWriteError.unsupportedAction) {
            _ = try await tracking.budgetHoldReview(month: "2026-07")
        }
    }

    @Test func templateOrEarlierEditMakesReviewedHoldStaleWithoutPartialWrite() async throws {
        let url = try makeHoldFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":10,"priority":0}]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "hold-stale")
        let review = try await database.budgetHoldReview(month: "2026-07")
        var holdBuilder = LocalFirstSyncMessageBuilder()
        let holdMessages = try await database.budgetHoldMessages(
            command: .hold(amount: 10_000), review: review, builder: &holdBuilder
        )

        var templateBuilder = LocalFirstSyncMessageBuilder()
        let template = try await database.budgetTemplateApply(
            command: .category("groceries"), month: "2026-07", builder: &templateBuilder
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(template.messages)
        let before = try await database.pendingLocalSyncMessageCount()

        await #expect(throws: LocalFirstError.budgetHoldReviewStale) {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(
                holdMessages,
                expectedMode: review.modeIdentity,
                expectedHoldReview: review
            )
        }
        #expect(try await database.pendingLocalSyncMessageCount() == before)
        #expect(try await database.budgetHoldReview(month: "2026-07").heldAmount == 0)

        let afterTemplateReview = try await database.budgetHoldReview(month: "2026-07")
        var secondHoldBuilder = LocalFirstSyncMessageBuilder()
        let secondHoldMessages = try await database.budgetHoldMessages(
            command: .hold(amount: 5_000),
            review: afterTemplateReview,
            builder: &secondHoldBuilder
        )
        var earlierEditBuilder = LocalFirstSyncMessageBuilder()
        let earlierEdit = try await database.assignCategoryBudgetMessages(
            categoryID: "groceries",
            budgeted: 10_000,
            month: "2026-06",
            builder: &earlierEditBuilder
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(earlierEdit)

        await #expect(throws: LocalFirstError.budgetHoldReviewStale) {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(
                secondHoldMessages,
                expectedMode: afterTemplateReview.modeIdentity,
                expectedHoldReview: afterTemplateReview
            )
        }
    }

    @Test func offlineHoldSurvivesDatabaseReopenWithOutbox() async throws {
        let url = try makeHoldFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "hold-offline")
        let review = try await database.budgetHoldReview(month: "2026-07")
        try await apply(.hold(amount: 30_000), review: review, to: database)
        let pendingCount = try await database.pendingLocalSyncMessageCount()

        let reopened = try BudgetDatabase(databaseURL: url, localNodeID: "hold-offline")
        #expect(try await reopened.budgetHoldReview(month: "2026-07").heldAmount == 30_000)
        #expect(try await reopened.pendingLocalSyncMessageCount() == pendingCount)
    }

    @Test func holdCreatesPreviouslyUnlistedFutureMonth() async throws {
        let database = try BudgetDatabase(databaseURL: makeHoldFixture(), localNodeID: "future-hold")
        let review = try await database.budgetHoldReview(month: "2027-01")
        #expect(review.toBudget > 0)
        try await apply(.hold(amount: 1_000), review: review, to: database)
        #expect(try await database.budgetHoldReview(month: "2027-01").heldAmount == 1_000)
        #expect(try await database.budgetHoldReview(month: "2027-02").heldAmount == 0)
    }

    @Test func holdPreservesNumericMonthRowIdentity() async throws {
        let url = try makeHoldFixture(holdTableSQL: """
            CREATE TABLE zero_budget_months (id INTEGER PRIMARY KEY, buffered INTEGER);
            INSERT INTO zero_budget_months VALUES (202607, 20000);
            """)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "hold-numeric-month")

        let review = try await database.budgetHoldReview(month: "2026-07")
        try await apply(.hold(amount: 10_000), review: review, to: database)

        let holdMessages = try await database.pendingLocalSyncMessages()
            .map(\.message)
            .filter { $0.dataset == "zero_budget_months" }
        #expect(holdMessages.map(\.row) == ["202607"])
        #expect(try await database.budgetHoldReview(month: "2026-07").manualHeldAmount == 30_000)
        let queue = await database.queue
        let rowCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM zero_budget_months")
        }
        #expect(rowCount == 1)
    }

    @Test func holdRejectsDuplicateCanonicalMonthRows() async throws {
        let url = try makeHoldFixture(extraSQL: """
            INSERT INTO zero_budget_months VALUES ('2026-07', 20000);
            INSERT INTO zero_budget_months VALUES ('202607', 20000);
            """)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "hold-duplicate-month")
        let review = try await database.budgetHoldReview(month: "2026-07")

        await #expect(throws: LocalFirstError.invalidLocalWrite("duplicate hold rows for month")) {
            var builder = LocalFirstSyncMessageBuilder()
            _ = try await database.budgetHoldMessages(
                command: .hold(amount: 10_000), review: review, builder: &builder
            )
        }
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
    }

    @Test func twoSyntheticPeersConvergeAfterHoldAndReset() async throws {
        let firstURL = try makeHoldFixture()
        let secondURL = try makeHoldFixture()
        let first = try BudgetDatabase(databaseURL: firstURL, localNodeID: "hold-peer-a")
        let second = try BudgetDatabase(databaseURL: secondURL, localNodeID: "hold-peer-b")

        let firstReview = try await first.budgetHoldReview(month: "2026-07")
        try await apply(.hold(amount: 45_000), review: firstReview, to: first)
        _ = try await second.applyRemoteSyncMessages(
            try await first.pendingLocalSyncMessages().map(\.message)
        )
        #expect(try await second.budgetHoldReview(month: "2026-07").heldAmount == 45_000)

        let secondReview = try await second.budgetHoldReview(month: "2026-07")
        try await apply(.reset, review: secondReview, to: second)
        _ = try await first.applyRemoteSyncMessages(
            try await second.pendingLocalSyncMessages().map(\.message)
        )

        let firstFinal = try await first.budgetHoldReview(month: "2026-07")
        let secondFinal = try await second.budgetHoldReview(month: "2026-07")
        #expect(firstFinal.heldAmount == 0)
        #expect(firstFinal.toBudget == secondFinal.toBudget)
        #expect(firstFinal.heldAmount == secondFinal.heldAmount)
    }

    @Test func storeHoldUsesReviewedCommitReloadAndBudgetGuard() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            CREATE TABLE zero_budget_months (id TEXT PRIMARY KEY, buffered INTEGER);
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 10);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
                VALUES ('salary', 'Salary', 'income-group', 1, 0, 0, 1, NULL);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                 description, notes, cleared, transferred_id, isChild)
                VALUES ('salary-jul', 'checking', 20260701, 200000, 'salary', 0, NULL, 0,
                        NULL, NULL, 0, NULL, 0);
            """)
        let review = try await store.budgetHoldReview(budgetID: "group-1", month: "2026-07")
        let loaded = try await store.applyBudgetHoldAndRefresh(
            command: .hold(amount: 25_000), review: review, budgetID: "group-1"
        )
        #expect(loaded.month.forNextMonth == 25_000)
        #expect(loaded.month.toBudget == review.toBudget - 25_000)
        await #expect(throws: LocalFirstError.budgetNotOpened) {
            _ = try await store.budgetHoldReview(budgetID: "another-budget", month: "2026-07")
        }
    }

    @Test func cancellationDuringCommitStillReturnsReloadedOwnedSession() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: """
            CREATE TABLE zero_budget_months (id TEXT PRIMARY KEY, buffered INTEGER);
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 10);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
                VALUES ('salary', 'Salary', 'income-group', 1, 0, 0, 1, NULL);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                 description, notes, cleared, transferred_id, isChild)
                VALUES ('salary-jul', 'checking', 20260701, 200000, 'salary', 0, NULL, 0,
                        NULL, NULL, 0, NULL, 0);
            """)
        let cancelOperation = Mutex<(@Sendable () -> Void)?>(nil)
        let didCancel = Mutex(false)
        let database = try BudgetDatabase(
            databaseURL: bundle.fileManager.databaseURL(fileID: "file-1"),
            localNodeID: "hold-cancel",
            beforeBudgetDataMutation: {
                let cancel = cancelOperation.withLock { $0 }
                guard let cancel else { return }
                didCancel.withLock { $0 = true }
                cancel()
            }
        )
        bundle.store.database = database
        let review = try await bundle.store.budgetHoldReview(budgetID: "group-1", month: "2026-07")

        let operation = Task { @MainActor in
            try await bundle.store.applyBudgetHoldAndRefresh(
                command: .hold(amount: 25_000), review: review, budgetID: "group-1"
            )
        }
        cancelOperation.withLock { cancel in
            cancel = { operation.cancel() }
        }
        let loaded = try await operation.value

        #expect(didCancel.withLock { $0 })
        #expect(loaded.month.forNextMonth == 25_000)
        #expect(loaded.month.toBudget == review.toBudget - 25_000)
        #expect(bundle.store.cachedBudgetMonth(budgetID: "group-1") == loaded)
        #expect(try await database.budgetHoldReview(month: "2026-07").heldAmount == 25_000)
    }

    private func apply(
        _ command: BudgetHoldCommand,
        review: BudgetHoldReview,
        to database: BudgetDatabase
    ) async throws {
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetHoldMessages(
            command: command,
            review: review,
            builder: &builder
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(
            messages,
            expectedMode: review.modeIdentity,
            expectedHoldReview: review
        )
    }

    private func makeHoldFixture(
        holdTableSQL: String = "CREATE TABLE zero_budget_months (id TEXT PRIMARY KEY, buffered INTEGER);",
        extraSQL: String = "",
        incomeAmount: Int = 200_000
    ) throws -> URL {
        try makeSQLiteFixture(extraSQL: """
            \(holdTableSQL)
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 10);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-group', 1, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions VALUES (
                'salary-jul', 'checking', 20260701, \(incomeAmount), 'salary', 0, NULL, 0
            );
            \(extraSQL)
            """)
    }
}
