import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct TransactionClearedSwipeCoordinatorTests {
    private typealias Fixture = TransactionBatchDeleteTests
    private let base = TransactionBatchMutationTests()

    private struct State: Equatable {
        let cleared: Int
        let reconciled: Int
    }

    private func state(
        _ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle,
        _ id: String
    ) throws -> State? {
        try base.readRows(bundle) { db in
            try Row.fetchOne(db, sql: "SELECT cleared, reconciled FROM transactions WHERE id = ?", arguments: [id])
                .map { State(cleared: $0["cleared"] as Int? ?? 0, reconciled: $0["reconciled"] as Int? ?? 0) }
        }
    }

    private func row(
        _ id: String,
        cleared: Bool,
        reconciled: Bool = false,
        isChild: Bool = false
    ) -> ActualTransaction {
        ActualTransaction(
            id: id, account: "checking", date: "2026-07-05", amount: -500,
            payee: nil, payeeName: nil, importedPayee: nil, category: "groceries", notes: nil,
            cleared: .bool(cleared), reconciled: reconciled,
            isChild: isChild, parentID: isChild ? "p" : nil
        )
    }

    private func toggle(
        _ coordinator: TransactionClearedSwipeCoordinator,
        _ transaction: ActualTransaction,
        bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle
    ) async -> Int {
        var commits = 0
        await coordinator.toggle(
            transaction,
            context: base.context(for: bundle.store),
            batchRepository: bundle.store.transactionCommands,
            transactionRepository: bundle.store.transactions
        ) { _ in commits += 1 }
        return commits
    }

    @Test func swipingAnUnclearedRowClearsIt() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL: Fixture.row("t", amount: -500))
        let coordinator = TransactionClearedSwipeCoordinator()

        let commits = await toggle(coordinator, row("t", cleared: false), bundle: bundle)

        #expect(commits == 1)
        #expect(try state(bundle, "t") == State(cleared: 1, reconciled: 0))
        #expect(coordinator.successFeedback == 1)
        #expect(coordinator.errorMessage == nil)
        #expect(coordinator.pendingTransactionID == nil)
    }

    @Test func swipingAClearedRowUnclearsIt() async throws {
        let bundle = try await base.makeBatchFixture(additionalFixtureSQL: Fixture.row("t", amount: -500, cleared: true))
        let coordinator = TransactionClearedSwipeCoordinator()

        let commits = await toggle(coordinator, row("t", cleared: true), bundle: bundle)

        #expect(commits == 1)
        #expect(try state(bundle, "t") == State(cleared: 0, reconciled: 0))
    }

    @Test func swipingAReconciledRowAsksBeforeUnlockingAndKeepsItCleared() async throws {
        // Unlocking reads the account's reconciliation state, which needs `last_reconciled`.
        let bundle = try await base.makeBatchFixture(
            additionalFixtureSQL: "ALTER TABLE accounts ADD COLUMN last_reconciled TEXT;\n"
                + Fixture.row("t", amount: -500, cleared: true, reconciled: true)
        )
        let coordinator = TransactionClearedSwipeCoordinator()

        let commits = await toggle(coordinator, row("t", cleared: true, reconciled: true), bundle: bundle)

        #expect(commits == 0)
        #expect(try state(bundle, "t") == State(cleared: 1, reconciled: 1), "nothing changes before confirmation")
        let request = try #require(coordinator.unlockRequest)
        #expect(request.presentation.intent == .unlock)
        #expect(request.id == "t")

        var unlocked = 0
        await coordinator.confirmUnlock(transactionRepository: bundle.store.transactions) { unlocked += 1 }

        #expect(unlocked == 1)
        #expect(coordinator.unlockRequest == nil)
        #expect(try state(bundle, "t") == State(cleared: 1, reconciled: 0))
    }

    @Test func aResetDropsAPendingUnlock() async throws {
        let bundle = try await base.makeBatchFixture(
            additionalFixtureSQL: Fixture.row("t", amount: -500, cleared: true, reconciled: true)
        )
        let coordinator = TransactionClearedSwipeCoordinator()
        _ = await toggle(coordinator, row("t", cleared: true, reconciled: true), bundle: bundle)

        coordinator.reset()
        var unlocked = 0
        await coordinator.confirmUnlock(transactionRepository: bundle.store.transactions) { unlocked += 1 }

        #expect(unlocked == 0)
        #expect(try state(bundle, "t") == State(cleared: 1, reconciled: 1))
    }

    @Test func splitPiecesAndRowsWithoutAnIDHaveNoSwipe() {
        #expect(TransactionClearedSwipeAction.isAvailable(for: row("t", cleared: false)))
        #expect(!TransactionClearedSwipeAction.isAvailable(for: row("c1", cleared: false, isChild: true)))
        let unsaved = ActualTransaction(
            id: nil, account: "checking", date: "2026-07-05", amount: -500,
            payee: nil, payeeName: nil, importedPayee: nil, category: nil, notes: nil, cleared: nil
        )
        #expect(!TransactionClearedSwipeAction.isAvailable(for: unsaved))
    }

    @Test func theActionFollowsTheRowStatus() {
        #expect(TransactionClearedSwipeAction(status: .uncleared) == .clear)
        #expect(TransactionClearedSwipeAction(status: .cleared) == .unclear)
        #expect(TransactionClearedSwipeAction(status: .reconciled) == .unlock)
    }

    @Test func aCategoryFeedSwipesThroughTheSpendingScope() throws {
        let account = ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false)
        let accountContext = try #require(TransactionClearedSwipeCoordinator.context(
            scope: .account(account), budgetID: "budget", sessionGeneration: 3
        ))
        #expect(accountContext.scope == .account("checking"))
        #expect(accountContext.sessionGeneration == 3)
        #expect(TransactionClearedSwipeCoordinator.context(
            scope: .spending, budgetID: "budget", sessionGeneration: 3
        )?.scope == .spending)
        #expect(TransactionClearedSwipeCoordinator.context(
            scope: .category(AccountTransactionsViewModelTests.categoryDetails), budgetID: "budget", sessionGeneration: 3
        )?.scope == .spending)
        #expect(TransactionClearedSwipeCoordinator.context(
            scope: .spending, budgetID: nil, sessionGeneration: 3
        ) == nil)
    }
}
