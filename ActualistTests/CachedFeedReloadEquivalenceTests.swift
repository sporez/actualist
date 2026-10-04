import Foundation
import GRDB
import Testing
@testable import Actualist

/// Phase 5.7: a reload serves every cached category and uncategorized feed from
/// one transaction-table read. The single-key refresh calls are the oracle.
@MainActor
struct CachedFeedReloadEquivalenceTests {
    private let fixtures = LocalFirstActualStoreTests()
    private static let budgetID = "group-1"

    private static let categoryScopes: [(String, String)] = [
        ("groceries", "2026-07"), ("groceries", "2026-06"), ("dining", "2025-03"),
        ("rent", "2026-01"), ("ghost", "2026-07"), ("salary", "2025-11"),
    ]
    private static let uncategorizedMonths = ["2026-07", "2026-06"]

    private static let kindsSQL = """
        UPDATE transactions SET category = NULL, description = 'coffee' WHERE id = 'txn';
        INSERT INTO transactions (
            id, acct, date, amount, category, tombstone, parent_id, is_parent, isChild, description
        ) VALUES
        ('june-uncat', 'checking', 20260615, -2500, NULL, 0, NULL, 0, 0, 'coffee'),
        ('july-cat', 'checking', 20260710, -800, 'groceries', 0, NULL, 0, 0, 'coffee'),
        ('july-split', 'checking', 20260712, -3000, NULL, 0, NULL, 1, 0, NULL),
        ('july-split-a', 'checking', 20260712, -1000, NULL, 0, 'july-split', 0, 1, 'coffee'),
        ('july-split-b', 'checking', 20260712, -2000, 'groceries', 0, 'july-split', 0, 1, 'coffee'),
        ('july-on-budget-xfer', 'checking', 20260720, -4000, NULL, 0, NULL, 0, 0, 'xfer-savings'),
        ('july-off-budget-xfer', 'checking', 20260721, -1500, NULL, 0, NULL, 0, 0, 'xfer-tracking'),
        ('july-tracking', 'tracking', 20260722, -900, NULL, 0, NULL, 0, 0, NULL);
        """

    /// Randomized history over the cached months, including split families.
    private static func historySQL(seed: UInt64) -> String {
        var rng = SplitMix64(seed: seed)
        let categories = ["groceries", "dining", "rent", "salary", "ghost", "NULL"]
        let months = [("2026", "07"), ("2026", "06"), ("2025", "03"), ("2026", "01"), ("2025", "11"), ("2025", "12")]
        var sql = ""
        for index in 0..<150 {
            let (year, month) = months[Int.random(in: 0..<months.count, using: &rng)]
            let category = categories[Int.random(in: 0..<categories.count, using: &rng)]
            let quoted = category == "NULL" ? "NULL" : "'\(category)'"
            let amount = Int.random(in: -9_000...9_000, using: &rng)
            let day = String(format: "%02d", Int.random(in: 1...28, using: &rng))
            if index % 10 == 0 {
                let split = Int.random(in: 0..<categories.count - 1, using: &rng)
                sql += """
                    INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, isChild, description)
                    VALUES ('h\(index)', 'checking', \(year)\(month)\(day), \(amount), NULL, 0, NULL, 1, 0, NULL),
                    ('h\(index)-a', 'checking', \(year)\(month)\(day), \(amount / 2), '\(categories[split])', 0, 'h\(index)', 0, 1, 'coffee'),
                    ('h\(index)-b', 'checking', \(year)\(month)\(day), \(amount - amount / 2), NULL, 0, 'h\(index)', 0, 1, 'coffee');

                    """
            } else {
                sql += "INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, isChild, description) VALUES ('h\(index)', 'checking', \(year)\(month)\(day), \(amount), \(quoted), \(index % 17 == 0 ? 1 : 0), NULL, 0, 0, 'coffee');\n"
            }
        }
        return sql
    }

    private func openedStore(seed: UInt64) async throws -> LocalFirstActualStore {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: Self.kindsSQL + Self.historySQL(seed: seed)
        )
        return bundle.store
    }

    private func cacheEveryKey(_ store: LocalFirstActualStore, categories: Int, months: Int) async throws {
        for (category, month) in Self.categoryScopes.prefix(categories) {
            try await store.refreshCategoryTransactions(budgetID: Self.budgetID, categoryID: category, month: month)
        }
        for month in Self.uncategorizedMonths.prefix(months) {
            _ = try await store.uncategorizedTransactions(budgetID: Self.budgetID, month: month)
        }
    }

    @Test(arguments: [UInt64(1), 2, 3])
    func reloadMatchesSingleKeyRefreshForEveryKeyKind(seed: UInt64) async throws {
        let store = try await openedStore(seed: seed)
        try await cacheEveryKey(store, categories: Self.categoryScopes.count, months: Self.uncategorizedMonths.count)
        let database = try #require(store.database)
        // Change the data so the reload has something to replace.
        let queue = await database.queue
        try await queue.write { db in
            try db.execute(sql: "UPDATE transactions SET category = NULL WHERE id = 'july-cat'")
            try db.execute(sql: "UPDATE transactions SET category = 'groceries' WHERE id = 'june-uncat'")
        }
        try await store.reloadSelectedBudgetCache(budgetID: Self.budgetID)

        var compared = 0
        for (category, month) in Self.categoryScopes {
            let reloaded = try #require(store.cachedCategoryTransactions(
                budgetID: Self.budgetID, categoryID: category, month: month))
            try await store.refreshCategoryTransactions(budgetID: Self.budgetID, categoryID: category, month: month)
            let oracle = try #require(store.cachedCategoryTransactions(
                budgetID: Self.budgetID, categoryID: category, month: month))
            #expect(reloaded == oracle, "category \(category) \(month) seed \(seed)")
            compared += 1
        }
        for month in Self.uncategorizedMonths {
            let reloaded = try #require(store.cachedUncategorizedTransactions(budgetID: Self.budgetID, month: month))
            let oracle = try await store.uncategorizedTransactions(budgetID: Self.budgetID, month: month)
            #expect(reloaded == oracle, "uncategorized \(month) seed \(seed)")
            #expect(!reloaded.transactions.isEmpty)
            compared += 1
        }
        #expect(compared == Self.categoryScopes.count + Self.uncategorizedMonths.count)
        let groceriesJuly = try #require(store.cachedCategoryTransactions(
            budgetID: Self.budgetID, categoryID: "groceries", month: "2026-07"))
        #expect(!groceriesJuly.transactions.contains { $0.id == "july-cat" })
    }

    @Test func reloadReadsTheTransactionTableOncePerKindNotPerKey() async throws {
        let store = try await openedStore(seed: 4)
        let database = try #require(store.database)
        let log = StatementLog()

        func tableReads(_ body: () async throws -> Void) async throws -> Int {
            let before = log.statements.count
            try await body()
            return log.statements.dropFirst(before).filter {
                $0.contains("FROM \"transactions\"") || $0.contains("FROM transactions")
            }.count
        }
        try await database.startStatementTraceForTesting(log)
        // A reload with no cached feeds still re-reads the selected month.
        let baseline = try await tableReads {
            try await store.reloadSelectedBudgetCache(budgetID: Self.budgetID)
        }
        try await cacheEveryKey(store, categories: Self.categoryScopes.count, months: 1)
        // The cost of one single-key refresh of each kind.
        let oneCategory = try await tableReads {
            try await store.refreshCategoryTransactions(budgetID: Self.budgetID, categoryID: "groceries", month: "2026-07")
        }
        let oneUncategorized = try await tableReads {
            _ = try await store.uncategorizedTransactions(budgetID: Self.budgetID, month: "2026-07")
        }
        #expect(oneCategory > 0 && oneUncategorized > 0)
        let reload = try await tableReads {
            try await store.reloadSelectedBudgetCache(budgetID: Self.budgetID)
        }
        try await database.stopStatementTraceForTesting()
        // Six category feeds and one uncategorized feed: the reload pays for
        // one category read and one uncategorized read, not one per key
        // (it was 6 * oneCategory + oneUncategorized).
        #expect(Self.categoryScopes.count == 6)
        #expect(reload - baseline == oneCategory + oneUncategorized, "reload \(reload), baseline \(baseline), category \(oneCategory), uncategorized \(oneUncategorized)")
    }
}
