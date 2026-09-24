import Foundation
import GRDB
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func filteredFeedCachesRemainDistinctAcrossSearchPaginationAndCacheRefresh() async throws {
        let database = try TransactionStatusFilterTestSupport.database()
        let store = makeStore()
        store.openedBudgetID = "status-budget"
        store.database = database
        store.accountsByBudget["status-budget"] = try await database.fetchAccountDisplays()

        try await store.refreshAccountTransactions(budgetID: "status-budget", accountID: "checking")
        try await store.refreshAccountTransactions(
            budgetID: "status-budget", accountID: "checking", statusFilter: .cleared
        )
        try await store.refreshSpendingTransactions(
            budgetID: "status-budget", statusFilter: .uncategorized
        )

        let all = try #require(store.cachedAccountTransactions(budgetID: "status-budget", accountID: "checking"))
        let cleared = try #require(store.cachedAccountTransactions(
            budgetID: "status-budget", accountID: "checking", statusFilter: .cleared
        ))
        let uncategorized = try #require(store.cachedSpendingTransactions(
            budgetID: "status-budget", statusFilter: .uncategorized
        ))
        #expect(all.transactions.contains { $0.id == "status-reconciled" })
        #expect(cleared.transactions.compactMap(\.id).filter { $0.hasPrefix("status-") } == ["status-cleared"])
        #expect(cleared.balance == all.balance)
        #expect(uncategorized.transactions.contains { $0.id == "mixed-parent" })

        let firstSearch = try await store.searchSpendingTransactions(
            budgetID: "status-budget",
            query: "status-search-needle",
            limit: 50,
            offset: 0,
            statusFilter: .uncleared
        )
        let secondSearch = try await store.searchSpendingTransactions(
            budgetID: "status-budget",
            query: "status-search-needle",
            limit: 50,
            offset: firstSearch.nextOffset,
            statusFilter: .uncleared
        )
        #expect(firstSearch.transactions.count == 50)
        #expect(firstSearch.nextOffset == 50)
        #expect(!firstSearch.reachedEnd)
        #expect(secondSearch.transactions.count == 3)
        #expect(secondSearch.nextOffset == 53)
        #expect(secondSearch.reachedEnd)

        try await store.refreshLoadedTransactionFeedCaches(database: database, budgetID: "status-budget")
        #expect(store.cachedAccountTransactions(budgetID: "status-budget", accountID: "checking") == all)
        #expect(store.cachedAccountTransactions(
            budgetID: "status-budget", accountID: "checking", statusFilter: .cleared
        ) == cleared)
        #expect(store.cachedSpendingTransactions(
            budgetID: "status-budget", statusFilter: .uncategorized
        ) == uncategorized)
    }

    @Test func newerRefreshRejectsOlderPageAndLeavesNextPageAvailable() async throws {
        let database = try TransactionStatusFilterTestSupport.database()
        let gate = TransactionFeedReadGate()
        let store = LocalFirstActualStore(transactionFeedPageReadHook: { key, query, limit, offset in
            await gate.pauseIfRequested(key: key, query: query, limit: limit, offset: offset)
        })
        store.openedBudgetID = "status-budget"
        store.database = database
        store.accountsByBudget["status-budget"] = try await database.fetchAccountDisplays()
        try await store.refreshAccountTransactions(budgetID: "status-budget", accountID: "checking")

        gate.holdNextRead { key, query, _, offset in
            key == .account(budgetID: "status-budget", accountID: "checking")
                && query == nil && offset == store.transactionPageSize
        }
        let olderLoad = Task {
            try await store.loadOlderTransactions(budgetID: "status-budget", accountID: "checking")
        }
        await gate.waitUntilSuspended()

        try await store.refreshAccountTransactions(budgetID: "status-budget", accountID: "checking")
        gate.release()
        await #expect(throws: CancellationError.self) { try await olderLoad.value }

        try await store.loadOlderTransactions(budgetID: "status-budget", accountID: "checking")
        let completed = try #require(store.cachedAccountTransactions(
            budgetID: "status-budget", accountID: "checking"
        ))
        #expect(completed.transactions.count > 100)
        #expect(completed.reachedEnd)
    }

    @Test func concurrentOlderReadsKeepTheCommittedWindowAndNextOffset() async throws {
        let database = try TransactionStatusFilterTestSupport.database()
        try await TransactionStatusFilterTestSupport.appendTransactions(
            count: 120,
            prefix: "concurrent-older",
            to: database
        )
        let gate = TransactionFeedReadGate()
        let store = LocalFirstActualStore(transactionFeedPageReadHook: { key, query, limit, offset in
            await gate.pauseIfRequested(key: key, query: query, limit: limit, offset: offset)
        })
        store.openedBudgetID = "status-budget"
        store.database = database
        store.accountsByBudget["status-budget"] = try await database.fetchAccountDisplays()
        try await store.refreshAccountTransactions(budgetID: "status-budget", accountID: "checking")

        gate.holdNextRead { key, query, _, offset in
            key == .account(budgetID: "status-budget", accountID: "checking")
                && query == nil && offset == store.transactionPageSize
        }
        let supersededLoad = Task {
            try await store.loadOlderTransactions(budgetID: "status-budget", accountID: "checking")
        }
        await gate.waitUntilSuspended()

        try await store.loadOlderTransactions(budgetID: "status-budget", accountID: "checking")
        let committedPage = try #require(store.cachedAccountTransactions(
            budgetID: "status-budget", accountID: "checking"
        ))
        gate.release()
        await #expect(throws: CancellationError.self) { try await supersededLoad.value }
        #expect(store.cachedAccountTransactions(
            budgetID: "status-budget", accountID: "checking"
        ) == committedPage)

        try await store.loadOlderTransactions(budgetID: "status-budget", accountID: "checking")
        let completed = try #require(store.cachedAccountTransactions(
            budgetID: "status-budget", accountID: "checking"
        ))
        #expect(completed.nextOffset > committedPage.nextOffset)
        #expect(completed.reachedEnd)
    }

    @Test func supersededBulkRefreshRetriesAndPublishesEveryFilter() async throws {
        let database = try TransactionStatusFilterTestSupport.database()
        let fixtureURL = await database.databaseURL
        let gate = TransactionFeedReadGate()
        let store = LocalFirstActualStore(transactionFeedPageReadHook: { key, query, limit, offset in
            await gate.pauseIfRequested(key: key, query: query, limit: limit, offset: offset)
        })
        store.openedBudgetID = "status-budget"
        store.database = database
        store.accountsByBudget["status-budget"] = try await database.fetchAccountDisplays()
        try await store.refreshAccountTransactions(budgetID: "status-budget", accountID: "checking")
        try await store.refreshAccountTransactions(
            budgetID: "status-budget", accountID: "checking", statusFilter: .cleared
        )
        let initialCleared = try #require(store.cachedAccountTransactions(
            budgetID: "status-budget", accountID: "checking", statusFilter: .cleared
        ))

        gate.holdNextRead { key, query, _, offset in
            key == .account(budgetID: "status-budget", accountID: "checking", statusFilter: .cleared)
                && query == nil && offset == 0
        }
        let bulkRefresh = Task {
            try await store.refreshLoadedTransactionFeedCaches(database: database, budgetID: "status-budget")
        }
        await gate.waitUntilSuspended()

        let fixtureQueue = try DatabaseQueue(path: fixtureURL.path)
        try await fixtureQueue.write { db in
            try db.execute(sql: "UPDATE transactions SET reconciled = 1 WHERE id = 'status-cleared'")
        }
        try await store.refreshAccountTransactions(budgetID: "status-budget", accountID: "checking")
        let refreshedAll = try #require(store.cachedAccountTransactions(
            budgetID: "status-budget", accountID: "checking"
        ))
        #expect(refreshedAll.transactions.first { $0.id == "status-cleared" }?.reconciled == true)

        gate.release()
        try await bulkRefresh.value
        let refreshedCleared = try #require(store.cachedAccountTransactions(
            budgetID: "status-budget", accountID: "checking", statusFilter: .cleared
        ))
        #expect(refreshedCleared != initialCleared)
        #expect(!refreshedCleared.transactions.contains { $0.id == "status-cleared" })
        #expect(store.cachedAccountTransactions(budgetID: "status-budget", accountID: "checking") == refreshedAll)
    }

    @Test func searchResultFromClosedBudgetIsRejectedAfterReadCompletes() async throws {
        let database = try TransactionStatusFilterTestSupport.database()
        let gate = TransactionFeedReadGate()
        let store = LocalFirstActualStore(transactionFeedPageReadHook: { key, query, limit, offset in
            await gate.pauseIfRequested(key: key, query: query, limit: limit, offset: offset)
        })
        store.openedBudgetID = "status-budget"
        store.database = database
        store.accountsByBudget["status-budget"] = try await database.fetchAccountDisplays()

        gate.holdNextRead { key, query, _, _ in
            key == .spending(budgetID: "status-budget") && query == "status-search-needle"
        }
        let search = Task {
            try await store.searchSpendingTransactions(
                budgetID: "status-budget",
                query: "status-search-needle",
                limit: 50,
                offset: 0
            )
        }
        await gate.waitUntilSuspended()
        store.closeOpenBudget()
        store.openedBudgetID = "status-budget"
        store.database = database
        gate.release()

        await #expect(throws: CancellationError.self) { _ = try await search.value }
    }
}
