import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func moveMoneyRejectsIntMaxAmountInsteadOfTrapping() async throws {
        let store = try await makeOpenedWritableStore()

        await #expect(throws: LocalFirstError.self) {
            _ = try await store.moveMoneyAndRefresh(expectedMode: nil,
                command: BudgetMoveMoneyCommand(
                    fromCategoryID: "groceries",
                    toCategoryID: "dining",
                    amount: Int.max
                ),
                budgetID: "group-1",
                month: "2026-07"
            ) {}
        }
        #expect(try await store.recentBudgetActions(budgetID: "group-1").isEmpty)
    }

    @Test func moveMoneyRejectsAmountAboveTheBound() async throws {
        let store = try await makeOpenedWritableStore()
        let leg = BudgetMoveMoneyCommand(
            fromCategoryID: "groceries",
            toCategoryID: "dining",
            amount: BudgetMoveMoneyCommand.maximumAmount + 1
        )

        await #expect(throws: LocalFirstError.self) {
            _ = try await store.moveMoneyAndRefresh(expectedMode: nil,
                commands: [leg],
                budgetID: "group-1",
                month: "2026-07"
            ) {}
        }
    }
}
