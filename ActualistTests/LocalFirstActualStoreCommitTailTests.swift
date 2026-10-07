import Foundation
import Testing
@testable import Actualist

@MainActor
struct LocalFirstActualStoreCommitTailTests {
    private let support = LocalFirstActualStoreTests()

    private struct ReloadFailure: Error {}

    @MainActor
    private final class Fixture {
        var failFeedReads = false
        /// Runs inside the post-commit reload; cancels the caller and then
        /// throws, the way a cancelled reload surfaces.
        var onFeedRead: (@MainActor () throws -> Void)?
        var events: [LocalFirstSyncDebugEvent] = []
        var queuedCount: Int { events.filter { $0.outcome == .queued }.count }
    }

    private func makeStore(additionalFixtureSQL: String = "") async throws -> (LocalFirstActualStore, Fixture) {
        let bundle = try await support.makeOpenedWritableStoreBundle(additionalFixtureSQL: additionalFixtureSQL)
        let fixture = Fixture()
        let store = LocalFirstActualStore(
            keychain: bundle.keychain,
            fileManager: bundle.fileManager,
            syncDebugRecorder: { event in fixture.events.append(event) },
            transactionFeedPageReadHook: { _, _, _, _ in
                if fixture.failFeedReads { throw ReloadFailure() }
                try fixture.onFeedRead?()
            }
        )
        _ = try await store.openCachedBudget(bundle.budget)
        try await store.refreshAccountTransactions(budgetID: "group-1", accountID: "checking")
        return (store, fixture)
    }

    private var draft: TransactionDraft {
        TransactionDraft(
            accountID: "checking",
            date: Date(timeIntervalSince1970: 1_784_000_000),
            amountMinorUnits: -725,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: "tail",
            cleared: false,
            isTransfer: false
        )
    }

    @Test func failedReloadAfterCommitStillSchedulesFlushAndSucceeds() async throws {
        let (store, fixture) = try await makeStore()
        fixture.failFeedReads = true
        let queuedBefore = fixture.queuedCount

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}

        #expect(result.ok)
        #expect(fixture.queuedCount == queuedBefore + 1)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") > 0)
    }

    @Test func tailReportsRefreshPendingOnlyWhenReloadFails() async throws {
        let (store, fixture) = try await makeStore()
        let database = try store.requireDatabase(for: "group-1")

        let ok = try await store.finishCommittedWrite(database: database, budgetID: "group-1") {}
        #expect(!ok)
        #expect(fixture.queuedCount == 1)

        let pending = try await store.finishCommittedWrite(database: database, budgetID: "group-1") {
            throw ReloadFailure()
        }
        #expect(pending)
        #expect(fixture.queuedCount == 2)
    }

    @Test func attachedTailReportsCancelledReloadAsPendingAfterFlush() async throws {
        let (store, fixture) = try await makeStore()
        let database = try store.requireDatabase(for: "group-1")

        let pending = try await store.finishCommittedWrite(database: database, budgetID: "group-1") {
            throw CancellationError()
        }

        #expect(pending)
        #expect(fixture.queuedCount == 1)
    }

    // MARK: A committed write is never reported as cancelled (main-to-dev 2.2)

    @Test func cancelledCallerDuringReloadStillReportsCreateAsCommitted() async throws {
        let (store, fixture) = try await makeStore()
        let queuedBefore = fixture.queuedCount
        let coordinator = TransactionEditorSubmissionCoordinator()
        let caller = Task { @MainActor in
            await coordinator.execute(
                editingIdentity: .creating,
                draft: draft,
                budgetID: "group-1",
                repository: store
            )
        }
        fixture.onFeedRead = {
            caller.cancel()
            throw CancellationError()
        }

        let outcome = await caller.value

        guard case .succeeded(let committed) = outcome, let result = committed else {
            Issue.record("A committed create must succeed, got \(outcome)")
            return
        }
        #expect(result.ok)
        #expect(result.refreshPending)
        #expect(coordinator.submissionState == .clean)
        #expect(fixture.queuedCount == queuedBefore + 1)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") > 0)
    }

    @Test func cancelledCallerDuringReloadStillReportsMoveMoneyAsCommitted() async throws {
        let (store, fixture) = try await makeStore()
        let queuedBefore = fixture.queuedCount
        let caller = Task { @MainActor in
            try await store.moveMoneyAndRefresh(
                expectedMode: nil,
                command: BudgetMoveMoneyCommand(
                    fromCategoryID: "groceries", toCategoryID: "utilities", amount: 10_000
                ),
                budgetID: "group-1",
                month: "2026-07"
            ) {}
        }
        fixture.onFeedRead = {
            caller.cancel()
            throw CancellationError()
        }

        // Committed with the month not yet read back: nil, not a thrown cancellation.
        let loaded = try await caller.value

        #expect(loaded == nil)
        #expect(fixture.queuedCount == queuedBefore + 1)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") > 0)
    }

    @Test func cancelledCallerDuringReloadStillReportsHoldAsCommitted() async throws {
        let (store, fixture) = try await makeStore(additionalFixtureSQL: """
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
        let queuedBefore = fixture.queuedCount
        let caller = Task { @MainActor in
            try await store.applyBudgetHoldAndRefresh(
                command: .hold(amount: 25_000), review: review, budgetID: "group-1"
            )
        }
        fixture.onFeedRead = {
            caller.cancel()
            throw CancellationError()
        }

        let loaded = try await caller.value

        #expect(loaded == nil)
        #expect(fixture.queuedCount == queuedBefore + 1)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") > 0)
    }

    @Test func durableTailReportsPendingAndSessionAfterFailureAndRetirement() async throws {
        let (store, fixture) = try await makeStore()
        let database = try store.requireDatabase(for: "group-1")
        let generation = store.budgetSessionGeneration
        let requireSession: @MainActor () throws -> Void = { [store] in
            try store.requireSyncSession(database: database, budgetID: "group-1", generation: generation)
        }

        let failed: DurableCommitTailOutcome<Void> = await store.finishDurableCommit(
            database: database,
            budgetID: "group-1",
            requireSession: requireSession,
            reload: { throw ReloadFailure() }
        )
        #expect(failed.refreshPending)
        #expect(failed.sessionCurrent)
        #expect(fixture.queuedCount == 1)

        let clean: DurableCommitTailOutcome<Int> = await store.finishDurableCommit(
            database: database,
            budgetID: "group-1",
            requireSession: requireSession,
            reload: { 7 }
        )
        #expect(!clean.refreshPending)
        #expect(clean.value == 7)
        #expect(fixture.queuedCount == 2)

        store.closeOpenBudget()
        let retired: DurableCommitTailOutcome<Void> = await store.finishDurableCommit(
            database: database,
            budgetID: "group-1",
            requireSession: requireSession,
            reload: {}
        )
        #expect(retired.refreshPending)
        #expect(!retired.sessionCurrent)
    }
}
