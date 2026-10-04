import Foundation
import Testing
@testable import Actualist

@Suite @MainActor
struct LocalFirstActualStoreTransactionMergeTests {
    private typealias StoreFixtures = LocalFirstActualStoreTests

    @Test func commitRefreshesBothTransferAccountsMonthsFeedsAndReports() async throws {
        let bundle = try await makeTransferBundle()
        let store = bundle.store
        let database = try store.requireDatabase(for: "group-1")
        let range = ReportDateRange.dashboard(
            through: try StoreFixtures().makeDate(year: 2026, month: 8, day: 10)
        )
        try await store.refreshAccountTransactions(budgetID: "group-1", accountID: "checking")
        try await store.refreshAccountTransactions(budgetID: "group-1", accountID: "credit")
        try await store.refreshSpendingTransactions(budgetID: "group-1")
        _ = try await store.refreshReportsDashboard(budgetID: "group-1", range: range)
        #expect(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking") != nil)
        #expect(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit") != nil)
        #expect(store.cachedReportsDashboard(budgetID: "group-1", range: range) != nil)

        let review = try await store.reviewTransactionMerge(
            context: context(for: store),
            orderedTransactionIDs: ["txn", "root-b"]
        )
        let outcome = try await store.commitTransactionMerge(review: review, authorization: nil)

        #expect(outcome.receipt.changedAccountIDs == ["checking", "credit"])
        #expect(outcome.receipt.changedMonths == ["2026-07", "2026-08"])
        #expect(outcome.receipt.changedTransactionIDs == ["peer-a", "peer-b", "root-b", "txn"])
        #expect(!outcome.refreshPending)
        #expect(outcome.sessionCurrent)
        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let credit = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit"))
        let spending = try #require(store.cachedSpendingTransactions(budgetID: "group-1"))
        #expect(checking.transactions.contains { $0.id == "txn" })
        #expect(!checking.transactions.contains { $0.id == "root-b" })
        #expect(credit.transactions.contains { $0.id == "peer-a" })
        #expect(!credit.transactions.contains { $0.id == "peer-b" })
        #expect(!spending.transactions.contains { $0.id == "root-b" || $0.id == "peer-b" })
        #expect(store.cachedReportsDashboard(budgetID: "group-1", range: range) == nil)
        #expect(try await database.recentBudgetActions().count == 1)
    }

    @Test func failedPostCommitRefreshReturnsReceiptAndInvalidatesPotentiallyStaleFeeds() async throws {
        let behavior = MergeRefreshBehavior()
        let bundle = try await makeTransferBundle(
            transactionFeedPageReadHook: { _, _, _, _ in
                if behavior.failReads { throw MergeRefreshError.expectedFailure }
            }
        )
        let store = bundle.store
        try await store.refreshAccountTransactions(budgetID: "group-1", accountID: "checking")
        try await store.refreshAccountTransactions(budgetID: "group-1", accountID: "credit")
        try await store.refreshSpendingTransactions(budgetID: "group-1")
        behavior.failReads = true
        let review = try await store.reviewTransactionMerge(
            context: context(for: store),
            orderedTransactionIDs: ["txn", "root-b"]
        )

        let outcome = try await store.commitTransactionMerge(review: review, authorization: nil)

        #expect(outcome.receipt.actionID == review.id)
        #expect(outcome.refreshPending)
        #expect(outcome.sessionCurrent)
        #expect(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking") == nil)
        #expect(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit") == nil)
        #expect(store.cachedSpendingTransactions(budgetID: "group-1") == nil)
        #expect(try await store.recentBudgetActions(budgetID: "group-1").count == 1)
    }

    @Test func closingSessionDuringPostCommitRefreshReturnsDurableReceipt() async throws {
        let gate = MergeRefreshGate()
        let bundle = try await makeTransferBundle(
            transactionFeedPageReadHook: { _, _, _, _ in await gate.pauseIfRequested() }
        )
        let store = bundle.store
        let database = try store.requireDatabase(for: "group-1")
        try await store.refreshAccountTransactions(budgetID: "group-1", accountID: "checking")
        let review = try await store.reviewTransactionMerge(
            context: context(for: store),
            orderedTransactionIDs: ["txn", "root-b"]
        )
        gate.requestPause()
        let commit = Task { try await store.commitTransactionMerge(review: review, authorization: nil) }
        guard await gate.waitForEntry() else {
            gate.release()
            _ = try? await commit.value
            Issue.record("The merge refresh did not reach its bounded gate")
            return
        }

        store.closeOpenBudget()
        gate.release()
        let outcome = try await commit.value

        #expect(outcome.receipt.actionID == review.id)
        #expect(outcome.refreshPending)
        #expect(!outcome.sessionCurrent)
        #expect(try await database.actionLogRecord(id: review.id)?.status == .applied)
    }

    private func makeTransferBundle(
        transactionFeedPageReadHook: TransactionFeedPageReadHook? = nil
    ) async throws -> StoreFixtures.OpenedWritableStoreBundle {
        try await StoreFixtures().makeOpenedWritableStoreBundle(
            keychainBackend: FakeKeychainBackend(),
            additionalFixtureSQL: """
            ALTER TABLE transactions ADD COLUMN reconciled INTEGER;
            ALTER TABLE transactions ADD COLUMN sort_order REAL;
            ALTER TABLE transactions ADD COLUMN error TEXT;
            UPDATE transactions SET amount = -1000, date = 20260703, reconciled = 0,
                                    description = 'xfer-credit', transferred_id = 'peer-a'
                WHERE id = 'txn';
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('peer-a', 'credit', 20260703, 1000, NULL, 0, NULL, 0,
                        'xfer-checking', NULL, 0, 0, 'txn', 0, NULL, NULL);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('root-b', 'checking', 20260803, -1000, NULL, 0, NULL, 0,
                        'xfer-credit', NULL, 0, 0, 'peer-b', 0, NULL, NULL);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                                      description, notes, cleared, reconciled, transferred_id, isChild,
                                      sort_order, error)
                VALUES ('peer-b', 'credit', 20260803, 1000, NULL, 0, NULL, 0,
                        'xfer-checking', NULL, 0, 0, 'root-b', 0, NULL, NULL);
            """,
            transactionFeedPageReadHook: transactionFeedPageReadHook
        )
    }

    private func context(for store: LocalFirstActualStore) -> TransactionSelectionContext {
        TransactionSelectionContext(
            budgetID: "group-1",
            sessionGeneration: store.budgetSessionGeneration,
            scope: .spending,
            querySignature: TransactionFeedQuery.all.signature
        )
    }
}

@MainActor
private final class MergeRefreshBehavior {
    var failReads = false
}

@MainActor
private final class MergeRefreshGate {
    private let entered = TestLatch()
    private let released = TestLatch()
    private var requested = false
    private var didEnter = false

    func requestPause() { requested = true }

    func pauseIfRequested() async {
        guard requested, !didEnter else { return }
        didEnter = true
        entered.trip()
        await released.wait()
    }

    func waitForEntry(timeout: Duration = .seconds(10)) async -> Bool {
        let reached = await entered.wait(timeout: timeout) { [released] in released.trip() }
        return didEnter && reached
    }

    func release() { released.trip() }
}

private enum MergeRefreshError: Error, Sendable {
    case expectedFailure
}
