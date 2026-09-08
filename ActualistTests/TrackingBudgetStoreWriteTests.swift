import Foundation
import Testing
@testable import Actualist

@MainActor
extension LocalFirstActualStoreTests {
    @Test func staleModeIdentityIsForwardedThroughEveryBudgetStoreWrite() async throws {
        let store = try await makeOpenedWritableStore()
        let database = try #require(store.database)
        let current = try await database.fetchBudgetModeIdentity()
        let stale = BudgetModeIdentity(
            storageID: current.storageID,
            table: current.table,
            revision: current.revision == "stale" ? "other" : "stale"
        )
        var assigned = false
        var moved = false
        var movedBatch = false
        var templated = false
        var carried = false

        await #expect(throws: BudgetModeWriteError.budgetChanged) {
            _ = try await store.assignCategoryBudgetAndRefresh(
                expectedMode: stale,
                categoryID: "groceries",
                budgeted: 62_500,
                budgetID: "group-1",
                month: "2026-07",
                didAssign: { assigned = true }
            )
        }
        await #expect(throws: BudgetModeWriteError.budgetChanged) {
            _ = try await store.moveMoneyAndRefresh(
                expectedMode: stale,
                command: BudgetMoveMoneyCommand(
                    fromCategoryID: "groceries", toCategoryID: "utilities", amount: 1_000
                ),
                budgetID: "group-1",
                month: "2026-07",
                didMove: { moved = true }
            )
        }
        await #expect(throws: BudgetModeWriteError.budgetChanged) {
            _ = try await store.moveMoneyAndRefresh(
                expectedMode: stale,
                commands: [BudgetMoveMoneyCommand(
                    fromCategoryID: "groceries", toCategoryID: "utilities", amount: 1_000
                )],
                budgetID: "group-1",
                month: "2026-07",
                didMove: { movedBatch = true }
            )
        }
        await #expect(throws: BudgetModeWriteError.budgetChanged) {
            _ = try await store.applyBudgetTemplateAndRefresh(
                expectedMode: stale,
                command: .fillEmpty,
                budgetID: "group-1",
                month: "2026-07",
                didApply: { templated = true }
            )
        }
        await #expect(throws: BudgetModeWriteError.budgetChanged) {
            _ = try await store.setCategoryCarryoverAndRefresh(
                expectedMode: stale,
                categoryID: "utilities",
                carryover: true,
                budgetID: "group-1",
                startMonth: "2026-07",
                didSetCarryover: { carried = true }
            )
        }
        await #expect(throws: BudgetModeWriteError.budgetChanged) {
            _ = try await store.setAllExpenseCategoryCarryoverAndRefresh(
                expectedMode: stale,
                carryover: true,
                budgetID: "group-1",
                startMonth: "2026-07"
            )
        }

        #expect(!assigned)
        #expect(!moved)
        #expect(!movedBatch)
        #expect(!templated)
        #expect(!carried)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") == 0)
        #expect(try await store.recentBudgetActions(budgetID: "group-1").isEmpty)
    }
}
