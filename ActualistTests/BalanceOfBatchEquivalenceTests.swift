import Foundation
import GRDB
import Synchronization
import Testing
@testable import Actualist

extension BudgetDatabase {
    /// The batched balances with the number of transaction reads it issued.
    func balanceOfCountingReads(
        formulas: [String], cutoffs: [BalanceOfCutoff]
    ) throws -> (balances: [[String: Int]], reads: Int) {
        try queue.read { db in
            let reads = Mutex(0)
            db.trace { event in
                if case .statement(let statement) = event, statement.sql.contains("FROM transactions") {
                    reads.withLock { $0 += 1 }
                }
            }
            let balances = try prefetchBalanceOf(
                formulas: formulas, cutoffs: cutoffs, db: db, dateTimeZone: ActualDateOnly.utc)
            return (balances, reads.withLock { $0 })
        }
    }
}

/// Phase 5.8: BALANCE_OF reads each account once per batch and resolves every
/// draft's cutoff in memory. An independent in-memory model of the cutoff is the oracle (the
/// per-draft SQL SUM it replaced agreed with this batch on the same fixtures
/// before it was removed).
@MainActor
struct BalanceOfBatchEquivalenceTests {
    private let fixtures = LocalFirstActualStoreTests()

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    @Test func batchedCutoffsEqualTheModelAndReadEachAccountOnce() async throws {
        var rng = SeededGenerator(state: 7)
        let sortValues: [Double?] = [nil, 1, 2, 3, 2.5, -1]
        var model: [(account: String, day: Int, amount: Int, live: Bool, sortOrder: Double?)] = [
            // The fixture's own row has no sort order.
            ("checking", 20260703, -12_345, true, nil)
        ]
        var sql = ""
        sql += "ALTER TABLE transactions ADD COLUMN sort_order REAL;\n"
        sql += "INSERT INTO accounts VALUES ('sav', 'Savings', 0, 0, 0, 2);\n"
        for index in 0..<120 {
            let account = ["checking", "sav", "checking"].randomElement(using: &rng)!
            let day = 20260626 + Int.random(in: 0..<10, using: &rng)
            let amount = Int.random(in: -5_000...5_000, using: &rng)
            let tombstone = Int.random(in: 0..<8, using: &rng) == 0 ? 1 : 0
            let isParent = Int.random(in: 0..<10, using: &rng) == 0 ? 1 : 0
            let sortOrder = sortValues.randomElement(using: &rng)!
            let value = sortOrder.map { String($0) } ?? "NULL"
            model.append((account, day, amount, tombstone == 0 && isParent == 0, sortOrder))
            sql += """
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, sort_order)
                VALUES ('r\(index)', '\(account)', \(day), \(amount), NULL, \(tombstone), NULL, \(isParent), \(value));

                """
        }
        let database = try BudgetDatabase(databaseURL: fixtures.makeSQLiteFixture(extraSQL: sql))
        let formulas = ["=BALANCE_OF(\"Checking\")+BALANCE_OF(\"sav\")+BALANCE_OF(\"Missing\")"]
        let draftSortOrders: [Double?] = [nil, 1, 2, 2.5, 3, 10, -1]
        var cutoffs: [BudgetDatabase.BalanceOfCutoff] = []
        for offset in -1...11 {
            let day = try #require(ActualDateOnly.date(
                from: ActualDateOnly.dayID(from: Date(timeIntervalSince1970: 1_782_432_000 + Double(offset) * 86_400),
                                           timeZone: ActualDateOnly.utc), timeZone: ActualDateOnly.utc))
            for sortOrder in draftSortOrders { cutoffs.append(.init(date: day, sortOrder: sortOrder)) }
        }

        let result = try await database.balanceOfCountingReads(formulas: formulas, cutoffs: cutoffs)

        func expected(_ account: String, _ cutoff: BudgetDatabase.BalanceOfCutoff) -> Int {
            let day = Int(ActualDateOnly.dayID(from: cutoff.date, timeZone: ActualDateOnly.utc)
                .replacingOccurrences(of: "-", with: ""))!
            return model.filter { row in
                guard row.account == account, row.live else { return false }
                if row.day != day { return row.day < day }
                guard let rowOrder = row.sortOrder else { return false }
                guard let draftOrder = cutoff.sortOrder else { return true }
                return rowOrder < draftOrder
            }.reduce(0) { $0 + $1.amount }
        }
        #expect(result.balances.count == cutoffs.count)
        for (cutoff, balances) in zip(cutoffs, result.balances) {
            #expect(balances == ["Checking": expected("checking", cutoff), "sav": expected("sav", cutoff), "Missing": 0],
                    "\(ActualDateOnly.dayID(from: cutoff.date, timeZone: ActualDateOnly.utc)) sort \(String(describing: cutoff.sortOrder))")
        }
        #expect(Set(result.balances.flatMap { $0.values }).count > 10)
        // Work count: the batch reads each resolved account once, where one SUM
        // per draft and account would take \(cutoffs.count * 2).
        #expect(result.reads == 2)
    }
}
