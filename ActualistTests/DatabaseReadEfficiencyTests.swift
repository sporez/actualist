import Foundation
import GRDB
import Synchronization
import Testing
@testable import Actualist

@MainActor
struct DatabaseReadEfficiencyTests {
    private let fixtures = LocalFirstActualStoreTests()
    @Test(arguments: [1, 40])
    func budgetCategoryReadsStayConstantAsGroupsGrow(groupCount: Int) async throws {
        let sql = (0..<groupCount).map { index in
            """
            INSERT INTO category_groups VALUES ('g-\(index)', 'Group \(index)', 0, 0, 0, \(index + 2));
            INSERT INTO categories VALUES ('c-\(index)', 'Category \(index)', 'g-\(index)', 0, 0, 0, 1);
            INSERT INTO zero_budgets VALUES (202607, 'c-\(index)', 123, 0);
            """
        }.joined(separator: "\n")
        let database = try BudgetDatabase(databaseURL: fixtures.makeSQLiteFixture(extraSQL: sql))
        let reads = Mutex(0)
        let queue = await database.queue
        try await queue.read { db in
            db.trace { event in
                if case .statement(let statement) = event,
                   statement.sql.lowercased().contains("from categories") {
                    reads.withLock { $0 += 1 }
                }
            }
        }
        let month = try await database.fetchBudgetMonth(month: "2026-07")
        #expect(month.categoryGroups.count == groupCount + 1)
        #expect(month.categoryGroups.first?.categories.first?.id == "groceries")
        #expect(month.totalBudgeted == 50_000 + 123 * groupCount)
        #expect(month.totalSpent == -12_345)
        #expect(reads.withLock { $0 } == 2)
    }

    @Test func transactionNameMapsDoNotRankPayeesOrReadHistory() async throws {
        let database = try BudgetDatabase(databaseURL: fixtures.makeSQLiteFixture(extraSQL: """
            CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER);
            INSERT INTO payees VALUES ('merchant', 'Merchant', NULL, 0), ('transfer', '', 'checking', 0);
            ALTER TABLE transactions ADD COLUMN description TEXT;
            UPDATE transactions SET description = 'merchant';
            """))
        let store = fixtures.makeStore()
        let reads = Mutex(0)
        let queue = await database.queue
        try await queue.read { db in
            db.trace { event in
                if case .statement(let statement) = event,
                   statement.sql.lowercased().contains("from transactions") {
                    reads.withLock { $0 += 1 }
                }
            }
        }
        let maps = try await store.nameMaps(database)
        #expect(maps.payeeNames == ["merchant": "Merchant", "transfer": "Checking"])
        #expect(maps.transferAccountIDsByPayeeID == ["transfer": "checking"])
        #expect(reads.withLock { $0 } == 0)

        try await queue.write { db in
            try db.execute(sql: "UPDATE payees SET name = 'Renamed' WHERE id = 'merchant'")
            try db.execute(sql: "UPDATE payees SET tombstone = 1 WHERE id = 'transfer'")
        }
        let refreshed = try await store.nameMaps(database)
        #expect(refreshed.payeeNames == ["merchant": "Renamed"])
        #expect(refreshed.transferPayeeIDs.isEmpty)
    }
}
