import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
@Suite("Local-first transaction duplicate")
struct LocalFirstActualStoreTransactionDuplicateTests {
    private let support = LocalFirstActualStoreTests()

    @Test func repositoryCommitReloadsBothTransferAccountsAndSpendingFeed() async throws {
        let bundle = try await makeBundle(additionalFixtureSQL: transferFixtureSQL)
        let store = bundle.store
        let repository: any TransactionDuplicateRepositoryProtocol = store
        try await store.refreshSpendingTransactions(budgetID: "group-1")
        let selection = identity("source-transfer")

        let review = try await repository.reviewTransactionDuplicate(
            context: context(for: store),
            selections: [selection]
        )
        let cloneForChecking = try #require(review.allocations.first {
            $0.sourceTransactionID == "source-transfer"
        }?.duplicateTransactionID)
        let cloneForCredit = try #require(review.allocations.first {
            $0.sourceTransactionID == "source-transfer-peer"
        }?.duplicateTransactionID)
        let outcome = try await repository.commitTransactionDuplicate(review: review)

        #expect(outcome.receipt.actionID == review.id)
        #expect(outcome.receipt.changed.accounts == ["checking", "credit"])
        #expect(outcome.receipt.changed.months == ["2026-07"])
        #expect(outcome.receipt.changed.transactions.count == 4)
        #expect(!outcome.refreshPending)
        #expect(outcome.sessionCurrent)
        let checking = try #require(store.cachedAccountTransactions(
            budgetID: "group-1",
            accountID: "checking"
        ))
        let credit = try #require(store.cachedAccountTransactions(
            budgetID: "group-1",
            accountID: "credit"
        ))
        let spending = try #require(store.cachedSpendingTransactions(budgetID: "group-1"))
        #expect(checking.transactions.contains { $0.id == cloneForChecking })
        #expect(credit.transactions.contains { $0.id == cloneForCredit })
        #expect(spending.transactions.contains { $0.id == cloneForChecking })
    }

    @Test func reviewRowsNameTheTransferCounterpartAccount() async throws {
        let bundle = try await makeBundle(additionalFixtureSQL: transferFixtureSQL)
        let review = try await bundle.store.reviewTransactionDuplicate(
            context: context(for: bundle.store),
            selections: [identity("source-transfer")]
        )
        let names = review.groups.flatMap(\.rows).reduce(into: [String: String?]()) {
            $0[$1.sourceTransactionID] = $1.payeeName
        }
        #expect(names["source-transfer"] == "Credit Card")
        #expect(names["source-transfer-peer"] == "Checking")
    }

    @Test func staleSessionReviewCannotCommitAfterSameBudgetReopen() async throws {
        let bundle = try await makeBundle()
        let store = bundle.store
        let database = try store.requireDatabase(for: "group-1")
        let review = try await store.reviewTransactionDuplicate(
            context: context(for: store),
            selections: [identity("txn")]
        )
        let cloneID = try #require(review.allocations.first?.duplicateTransactionID)

        store.closeOpenBudget()
        _ = try await store.openCachedBudget(bundle.budget)
        await #expect(throws: CancellationError.self) {
            try await store.commitTransactionDuplicate(review: review)
        }

        #expect(try await database.actionLogRecord(id: review.id) == nil)
        #expect(try transactionExists(cloneID, bundle: bundle) == false)
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
    }

    @Test func sessionCloseDuringPostCommitRefreshReturnsDurableReceipt() async throws {
        let gate = DuplicatePostCommitRefreshGate()
        let bundle = try await makeBundle(transactionFeedPageReadHook: { _, _, _, _ in
            await gate.pause()
        })
        let store = bundle.store
        let database = try store.requireDatabase(for: "group-1")
        let review = try await store.reviewTransactionDuplicate(
            context: context(for: store),
            selections: [identity("txn")]
        )
        let commit = Task { try await store.commitTransactionDuplicate(review: review) }
        guard await gate.waitForEntry() else {
            gate.release()
            _ = try? await commit.value
            Issue.record("The post-commit feed refresh did not reach its bounded gate")
            return
        }

        store.closeOpenBudget()
        gate.release()
        let outcome = try await commit.value

        #expect(outcome.receipt.actionID == review.id)
        #expect(outcome.refreshPending)
        #expect(!outcome.sessionCurrent)
        #expect(try await database.actionLogRecord(id: review.id)?.status == .applied)
        #expect(try transactionExists(review.allocations[0].duplicateTransactionID, bundle: bundle))
        #expect(try await database.pendingLocalSyncMessageCount() > 0)
    }

    private func makeBundle(
        additionalFixtureSQL: String = "",
        transactionFeedPageReadHook: TransactionFeedPageReadHook? = nil
    ) async throws -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        try await support.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: """
                ALTER TABLE transactions ADD COLUMN reconciled INTEGER;
                ALTER TABLE transactions ADD COLUMN sort_order REAL;
                ALTER TABLE transactions ADD COLUMN error TEXT;
                \(additionalFixtureSQL)
                """,
            transactionFeedPageReadHook: transactionFeedPageReadHook
        )
    }

    private func context(for store: LocalFirstActualStore) -> TransactionSelectionContext {
        TransactionSelectionContext(
            budgetID: "group-1",
            sessionGeneration: store.budgetSessionGeneration,
            scope: .spending,
            querySignature: TransactionFeedQuery().signature
        )
    }

    private func identity(_ id: String) -> TransactionSelectionIdentity {
        TransactionSelectionIdentity(transactionID: id, familyRootID: id, role: .root)!
    }

    private func transactionExists(
        _ id: String,
        bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle
    ) throws -> Bool {
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM transactions WHERE id = ?)", arguments: [id]) ?? false
        }
    }

    private var transferFixtureSQL: String {
        """
        INSERT INTO transactions
            (id, acct, date, amount, category, tombstone, parent_id, is_parent,
             description, notes, cleared, transferred_id, isChild, reconciled)
        VALUES
            ('source-transfer', 'checking', 20260703, -1000, NULL, 0, NULL, 0,
             'xfer-credit', 'transfer note', 0, 'source-transfer-peer', 0, 0),
            ('source-transfer-peer', 'credit', 20260703, 1000, NULL, 0, NULL, 0,
             'xfer-checking', 'transfer note', 0, 'source-transfer', 0, 0);
        """
    }
}

@MainActor
private final class DuplicatePostCommitRefreshGate {
    private let entered = TestLatch()
    private let released = TestLatch()
    private var didEnter = false

    func pause() async {
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
