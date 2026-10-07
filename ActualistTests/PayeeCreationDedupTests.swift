import Foundation
import Testing
@testable import Actualist

/// Concurrency 5.2b (audit CA-12): two gestures that create the same new
/// payee name must share one payee. `userActionBeforeCommitHook` lets the
/// second gesture commit between the first one's resolution and its commit.
extension LocalFirstActualStoreTests {
    @Test func twoCreatesOfTheSameNewPayeeNameShareOnePayee() async throws {
        let store = try await makeOpenedWritableStore()
        func draft(amount: Int) throws -> TransactionDraft {
            TransactionDraft(
                accountID: "checking",
                date: try makeDate(year: 2026, month: 7, day: 11),
                amountMinorUnits: amount,
                payeeID: nil,
                payeeName: "Brand New Payee",
                categoryID: "groceries",
                notes: "",
                cleared: false,
                isTransfer: false
            )
        }
        let second = try draft(amount: -200)
        var secondID: String?
        // The second gesture resolves the same unknown name and commits first.
        store.seams.userActionBeforeCommitHook = { [store] in
            store.seams.userActionBeforeCommitHook = nil
            do {
                let result = try await store.createTransactionAndRefresh(second, budgetID: "group-1") {}
                secondID = result.changed.transactions.first
            } catch {
                Issue.record("the competing create failed: \(error)")
            }
        }

        let first = try await store.createTransactionAndRefresh(try draft(amount: -100), budgetID: "group-1") {}

        let database = try #require(store.database)
        let named = try await database.fetchPayees(orderedForPicker: false)
            .filter { $0.name == "Brand New Payee" }
        #expect(named.count == 1)
        let transactions = try await database.fetchTransactions()
        let firstPayee = transactions.first { $0.id == first.changed.transactions.first }?.payee
        let secondPayee = transactions.first { $0.id == secondID }?.payee
        #expect(firstPayee != nil)
        #expect(firstPayee == secondPayee)
        #expect(firstPayee == named.first?.id)
    }
}
