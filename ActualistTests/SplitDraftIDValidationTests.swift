import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    private func child(_ id: String?, amount: Int) -> TransactionSplitDraft {
        TransactionSplitDraft(id: id, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: amount)
    }

    /// Creates an unrelated simple transaction and returns its id.
    private func makeBystander(in store: LocalFirstActualStore) async throws -> String {
        let created = try await store.createTransactionAndRefresh(
            splitDraft(amount: -2_000, splits: []),
            budgetID: "group-1"
        ) {}
        return try #require(created.changed.transactions.first)
    }

    private func transaction(_ id: String, in store: LocalFirstActualStore) -> ActualTransaction? {
        parentTransaction(in: store, id: id)
    }

    @Test func createSplitWithAnExistingTransactionIDThrowsAndLeavesItUntouched() async throws {
        let store = try await makeOpenedWritableStore()
        let bystanderID = try await makeBystander(in: store)
        let before = try #require(transaction(bystanderID, in: store))

        await #expect(throws: (any Error).self) {
            _ = try await store.createTransactionAndRefresh(
                splitDraft(amount: -10_000, splits: [
                    child(bystanderID, amount: -4_000),
                    child("fresh-child", amount: -6_000),
                ]),
                budgetID: "group-1"
            ) {}
        }

        #expect(transaction(bystanderID, in: store) == before)
    }

    @Test func updateSplitWithAForeignChildIDThrowsAndLeavesBothFamiliesUntouched() async throws {
        let store = try await makeOpenedWritableStore()
        let bystanderID = try await makeBystander(in: store)
        let created = try await store.createTransactionAndRefresh(
            splitDraft(amount: -10_000, splits: [
                child("child-a", amount: -4_000),
                child("child-b", amount: -6_000),
            ]),
            budgetID: "group-1"
        ) {}
        let parentID = try #require(created.changed.transactions.first)
        let bystanderBefore = try #require(transaction(bystanderID, in: store))
        let parentBefore = try #require(transaction(parentID, in: store))

        await #expect(throws: (any Error).self) {
            _ = try await store.updateTransactionAndRefresh(
                parentID,
                with: splitDraft(amount: -10_000, splits: [
                    child("child-a", amount: -4_000),
                    child(bystanderID, amount: -6_000),
                ]),
                budgetID: "group-1",
                originalAccountID: "checking",
                originalMonth: "2026-07"
            ) {}
        }

        #expect(transaction(bystanderID, in: store) == bystanderBefore)
        #expect(transaction(parentID, in: store) == parentBefore)
    }

    @Test func updateSplitWhoseChildUsesTheParentIDThrows() async throws {
        let store = try await makeOpenedWritableStore()
        let created = try await store.createTransactionAndRefresh(
            splitDraft(amount: -10_000, splits: [child("child-a", amount: -10_000)]),
            budgetID: "group-1"
        ) {}
        let parentID = try #require(created.changed.transactions.first)
        let parentBefore = try #require(transaction(parentID, in: store))

        await #expect(throws: (any Error).self) {
            _ = try await store.updateTransactionAndRefresh(
                parentID,
                with: splitDraft(amount: -10_000, splits: [child(parentID, amount: -10_000)]),
                budgetID: "group-1",
                originalAccountID: "checking",
                originalMonth: "2026-07"
            ) {}
        }

        #expect(transaction(parentID, in: store) == parentBefore)
    }

    @Test func createSplitWithDuplicateChildIDsThrows() async throws {
        let store = try await makeOpenedWritableStore()

        await #expect(throws: (any Error).self) {
            _ = try await store.createTransactionAndRefresh(
                splitDraft(amount: -10_000, splits: [
                    child("dup", amount: -4_000),
                    child("dup", amount: -6_000),
                ]),
                budgetID: "group-1"
            ) {}
        }
    }

    @Test func updateSplitWithDuplicateChildIDsThrowsAndKeepsTheFamily() async throws {
        let store = try await makeOpenedWritableStore()
        let created = try await store.createTransactionAndRefresh(
            splitDraft(amount: -10_000, splits: [
                child("child-a", amount: -4_000),
                child("child-b", amount: -6_000),
            ]),
            budgetID: "group-1"
        ) {}
        let parentID = try #require(created.changed.transactions.first)
        let parentBefore = try #require(transaction(parentID, in: store))

        await #expect(throws: (any Error).self) {
            _ = try await store.updateTransactionAndRefresh(
                parentID,
                with: splitDraft(amount: -10_000, splits: [
                    child("child-a", amount: -4_000),
                    child("child-a", amount: -6_000),
                ]),
                budgetID: "group-1",
                originalAccountID: "checking",
                originalMonth: "2026-07"
            ) {}
        }

        #expect(transaction(parentID, in: store) == parentBefore)
    }
}
