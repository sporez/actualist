import Foundation
import Testing
@testable import Actualist

@MainActor
struct CategoryRolloverLifecycleTests {
    @Test(arguments: [false, true])
    func repeatedTogglesPreserveOpenCategoryFeed(tracking: Bool) async throws {
        let bundle = try await LocalFirstActualStoreTests().makeOpenedWritableStoreBundle(
            additionalFixtureSQL: tracking ? TrackingBudgetLifecycleTests.sql : ""
        )
        let store = bundle.store
        let loaded = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let category = try #require(loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })
        let details = CategoryMonthDetails(category: category, month: "2026-07", modeIdentity: loaded.modeIdentity)
        let model = CategoryMonthDetailsViewModel(details: details)
        let feed = AccountTransactionsViewModel(scope: .category(details))
        await feed.loadLocal(budgetID: "group-1", repository: store)
        let before = try #require(store.cachedCategoryTransactions(budgetID: "group-1", categoryID: "groceries", month: "2026-07"))
        #expect(!before.transactions.isEmpty)
        for enabled in [!category.carryover, category.carryover, !category.carryover] {
            await model.setCarryover(enabled, budgetID: "group-1", repository: store)
            #expect(model.carryoverErrorMessage == nil)
            #expect(model.isCarryoverEnabled == enabled)
            #expect(store.cachedCategoryTransactions(budgetID: "group-1", categoryID: "groceries", month: "2026-07") == before)
            let displayed = feed.displayState(budgetID: "group-1", repository: store,
                pendingNewTransactionIDs: [], privacyModeEnabled: false)
            #expect(displayed.transactionCount == before.transactions.count)
            #expect(displayed.hasLoadedSnapshot)
        }
    }

    @Test(arguments: ["sync", "transaction", "payee", "account", "calendar"])
    func refreshReplacesMembershipWithoutDroppingLoadedFeeds(source: String) async throws {
        let bundle = try await LocalFirstActualStoreTests().makeOpenedWritableStoreBundle(
            additionalFixtureSQL: TrackingBudgetLifecycleTests.sql
        )
        let store = bundle.store
        let database = try #require(store.database)
        _ = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-08")
        try await store.refreshCategoryTransactions(budgetID: "group-1", categoryID: "groceries", month: "2026-07")
        _ = try await store.uncategorizedTransactions(budgetID: "group-1", month: "2026-07")
        _ = try await database.applyRemoteSyncMessages([
            .init(timestamp: "2026-09-08T00:00:00.000Z-0000-0000000000000001", dataset: "transactions",
                row: "txn", column: "category", serializedValue: "0:")
        ])
        switch source {
        case "sync": try await store.reloadAfterRemoteSync(database: database, budgetID: "group-1")
        case "transaction": try await store.reloadAfterTransactionMutation(database: database, budgetID: "group-1", accountIDs: ["checking"], monthIDs: ["2026-07"])
        case "payee": try await store.reloadAfterPayeeMutation(database: database, budgetID: "group-1")
        case "account": try await store.reloadAfterAccountMutation(database: database, budgetID: "group-1")
        default: try await store.reloadSelectedBudgetCache(budgetID: "group-1")
        }
        let category = try #require(store.cachedCategoryTransactions(budgetID: "group-1", categoryID: "groceries", month: "2026-07"))
        #expect(category.transactions.isEmpty)
        let uncategorized = try #require(store.cachedUncategorizedTransactions(budgetID: "group-1", month: "2026-07"))
        #expect(uncategorized.transactions.contains { $0.id == "txn" })
    }

    @Test(arguments: [0, 30000])
    func negativeRolloverReducesNextMonthAssignment(octoberBudgeted: Int) async throws {
        let bundle = try await LocalFirstActualStoreTests().makeOpenedWritableStoreBundle(
            additionalFixtureSQL: TrackingBudgetLifecycleTests.sql + """
                DELETE FROM reflect_budgets;
                INSERT INTO reflect_budgets VALUES ('202609-groceries', 202609, 'groceries', 20000, 0);
                INSERT INTO reflect_budgets VALUES ('202610-groceries', 202610, 'groceries', \(octoberBudgeted), 0);
                UPDATE transactions SET date = 20260903, amount = -35000 WHERE id = 'txn';
                """
        )
        let store = bundle.store
        let september = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-09")
        #expect(september.month.totalBalance == -15000)
        _ = try await store.setCategoryCarryoverAndRefresh(expectedMode: september.modeIdentity,
            categoryID: "groceries", carryover: true, budgetID: "group-1", startMonth: "2026-09") {}
        let october = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-10")
        #expect(october.month.totalBalance == octoberBudgeted - 15000)
        store.reset()
        #expect(try await store.openCachedBudget(bundle.budget))
        #expect(try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-10").month == october.month)
    }
}
