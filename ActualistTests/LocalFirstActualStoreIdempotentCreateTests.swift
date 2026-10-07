import Foundation
import Testing
@testable import Actualist

/// A create that carries a caller-chosen id is idempotent: repeating it after
/// an ambiguous outcome never duplicates, and never resurrects a deleted row
/// (concurrency remediation 0.3, audit CA-01, decision D7).
@MainActor
struct LocalFirstActualStoreIdempotentCreateTests {
    private let support = LocalFirstActualStoreTests()

    private func makeStore() async throws -> LocalFirstActualStore {
        let store = try await support.makeOpenedWritableStore()
        try await store.refreshAccountTransactions(budgetID: "group-1", accountID: "checking")
        return store
    }

    private func draft(notes: String = "idem", transfer: Bool = false) -> TransactionDraft {
        TransactionDraft(
            accountID: "checking",
            date: Date(timeIntervalSince1970: 1_784_000_000),
            amountMinorUnits: -725,
            payeeID: transfer ? "xfer-tracking" : "coffee",
            payeeName: transfer ? "Tracking" : "Coffee Shop",
            categoryID: transfer ? nil : "groceries",
            notes: notes,
            cleared: false,
            isTransfer: transfer
        )
    }

    private func rows(_ store: LocalFirstActualStore, notes: String = "idem") -> [ActualTransaction] {
        (store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?.transactions ?? [])
            .filter { $0.notes == notes }
    }

    @Test func creatingWithTheSameIDTwiceWritesOneRowAndOneActionLogEntry() async throws {
        let store = try await makeStore()

        let first = try await store.createTransactionAndRefresh(
            draft(), budgetID: "group-1", transactionID: "txn-x"
        ) {}
        let pendingAfterFirst = try await store.pendingLocalSyncMessageCount(budgetID: "group-1")
        let didCreate = DidCreateCounter()
        let second = try await store.createTransactionAndRefresh(
            draft(), budgetID: "group-1", transactionID: "txn-x"
        ) { didCreate.count += 1 }

        #expect(first.changed.transactions == ["txn-x"])
        #expect(second.ok)
        #expect(second.changed.transactions == ["txn-x"])
        #expect(didCreate.count == 1)
        #expect(rows(store).map(\.id) == ["txn-x"])
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") == pendingAfterFirst)
        let creates = try await store.recentBudgetActions(budgetID: "group-1")
            .filter { $0.kind == .createTransaction }
        #expect(creates.count == 1)
    }

    @Test func retryingACreateAfterItsRowWasDeletedDoesNotResurrectIt() async throws {
        let store = try await makeStore()
        let created = try await store.createTransactionAndRefresh(
            draft(), budgetID: "group-1", transactionID: "txn-x"
        ) {}
        let row = try #require(rows(store).first)
        _ = try await store.deleteTransactionAndRefresh(row, budgetID: "group-1") {}
        #expect(rows(store).isEmpty)
        let pendingAfterDelete = try await store.pendingLocalSyncMessageCount(budgetID: "group-1")

        let retry = try await store.createTransactionAndRefresh(
            draft(), budgetID: "group-1", transactionID: "txn-x"
        ) {}

        #expect(created.ok && retry.ok)
        #expect(rows(store).isEmpty)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") == pendingAfterDelete)
    }

    @Test func retryingATransferCreateWritesNoSecondLeg() async throws {
        let store = try await makeStore()
        _ = try await store.createTransactionAndRefresh(
            draft(transfer: true), budgetID: "group-1", transactionID: "txn-x"
        ) {}
        let pendingAfterFirst = try await store.pendingLocalSyncMessageCount(budgetID: "group-1")

        _ = try await store.createTransactionAndRefresh(
            draft(transfer: true), budgetID: "group-1", transactionID: "txn-x"
        ) {}

        #expect(rows(store).count == 1)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") == pendingAfterFirst)
    }

    @Test func nilIDKeepsEveryCreateIndependent() async throws {
        let store = try await makeStore()

        _ = try await store.createTransactionAndRefresh(draft(), budgetID: "group-1") {}
        _ = try await store.createTransactionAndRefresh(draft(), budgetID: "group-1") {}

        #expect(rows(store).count == 2)
    }

    @Test func savingTheSameEditorPresentationTwiceCreatesOneTransaction() async throws {
        let store = try await makeStore()
        let coordinator = TransactionEditorMutationCoordinator(transaction: nil)

        let first = await coordinator.submit(
            validation: .valid, draft: draft(), budgetID: "group-1", repository: store
        )
        let second = await coordinator.submit(
            validation: .valid, draft: draft(), budgetID: "group-1", repository: store
        )

        #expect(first == .saved)
        #expect(second == .saved)
        #expect(rows(store).count == 1)
        let creates = try await store.recentBudgetActions(budgetID: "group-1")
            .filter { $0.kind == .createTransaction }
        #expect(creates.count == 1)
    }
}

@MainActor
private final class DidCreateCounter {
    var count = 0
}
