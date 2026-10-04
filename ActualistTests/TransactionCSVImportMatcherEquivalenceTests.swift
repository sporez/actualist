import Foundation
import Testing
@testable import Actualist

/// Phase 5.3: the CSV matcher indexes candidates once and the candidate fetch
/// is bounded to the file's date window. The pre-index matcher below is the
/// oracle, kept verbatim (it calls the same fill-rule `disposition`).
@MainActor
struct TransactionCSVImportMatcherEquivalenceTests {
    private let fixtures = LocalFirstActualStoreTests()

    private static let context = TransactionCSVImportMatchContext(
        payeeIDByName: ["alpha": "p-alpha", "beta": "p-beta", "to savings": "p-transfer", "gamma": "p-gamma"],
        transferPayeeIDs: ["p-transfer"],
        categoryIDByName: ["groceries": "cat-groceries", "dining": "cat-dining"]
    )

    /// The pre-Phase-5 O(rows x candidates) matcher.
    private static func naiveMatch(
        rows: [TransactionCSVImportRow],
        candidates: [TransactionCSVImportCandidate]
    ) -> [TransactionCSVImportDisposition] {
        var claimed: Set<String> = []
        var dispositions: [TransactionCSVImportDisposition] = []
        func fuzzy(_ row: TransactionCSVImportRow) -> [(candidate: TransactionCSVImportCandidate, distance: Int, order: Int)] {
            var matches: [(candidate: TransactionCSVImportCandidate, distance: Int, order: Int)] = []
            for (order, candidate) in candidates.enumerated() {
                guard !claimed.contains(candidate.id),
                      candidate.amountMinorUnits == row.amountMinorUnits,
                      let distance = ActualDateOnly.dayDistance(from: candidate.dateText, to: row.dateText),
                      abs(distance) <= TransactionCSVImportMatcher.fuzzyDateWindowDays else { continue }
                if row.importedID != nil && candidate.importedID != nil { continue }
                matches.append((candidate, abs(distance), order))
            }
            return matches.sorted {
                $0.distance == $1.distance ? $0.order < $1.order : $0.distance < $1.distance
            }
        }
        for row in rows {
            let payee = row.payeeName.isEmpty ? nil : context.payeeIDByName[row.payeeName.lowercased()]
            if let importedID = row.importedID, !importedID.isEmpty,
               let candidate = candidates.first(where: { !claimed.contains($0.id) && $0.importedID == importedID }) {
                claimed.insert(candidate.id)
                dispositions.append(TransactionCSVImportMatcher.disposition(
                    row: row, candidate: candidate, resolvedPayeeID: payee, context: context))
                continue
            }
            let pool = fuzzy(row)
            if let payee, let hit = pool.first(where: { $0.candidate.payeeID == payee }) {
                claimed.insert(hit.candidate.id)
                dispositions.append(TransactionCSVImportMatcher.disposition(
                    row: row, candidate: hit.candidate, resolvedPayeeID: payee, context: context))
                continue
            }
            if let nearest = pool.first {
                claimed.insert(nearest.candidate.id)
                dispositions.append(TransactionCSVImportMatcher.disposition(
                    row: row, candidate: nearest.candidate, resolvedPayeeID: payee, context: context))
                continue
            }
            dispositions.append(.insert(isTransfer: payee.map(Self.context.transferPayeeIDs.contains) ?? false))
        }
        return dispositions
    }

    private static func dayText(_ offset: Int) -> String {
        ActualScheduleRecurrence.dayID(from: Date(timeIntervalSince1970: Double(19_900 + offset) * 86_400))
    }

    private static func fixture(seed: UInt64, rowCount: Int, candidateCount: Int)
        -> (rows: [TransactionCSVImportRow], candidates: [TransactionCSVImportCandidate]) {
        var rng = SplitMix64(seed: seed)
        func pick<T>(_ values: [T]) -> T { values[Int.random(in: 0..<values.count, using: &rng)] }
        let amounts = [-1_234, -500, -500, 999, 0, 12_000]
        let payees = ["p-alpha", "p-beta", "p-gamma", "p-transfer", nil]
        let candidates = (0..<candidateCount).map { index in
            let day = Int.random(in: 0..<60, using: &rng)
            let broken = Int.random(in: 0..<25, using: &rng) == 0
            return TransactionCSVImportCandidate(
                id: "c-\(index)",
                importedID: Int.random(in: 0..<4, using: &rng) == 0 ? "imp-\(Int.random(in: 0..<6, using: &rng))" : nil,
                payeeID: pick(payees),
                categoryID: pick([nil, "", "cat-groceries"]),
                notes: pick([nil, "", "note"]),
                cleared: pick([nil, true, false]),
                importedPayee: pick([nil, "Alpha", "Beta"]),
                amountMinorUnits: pick(amounts),
                dateText: broken ? pick(["2026-02-30", "garbage", "", "2026-1-05"]) : dayText(day),
                reconciled: Int.random(in: 0..<8, using: &rng) == 0,
                isParent: Int.random(in: 0..<10, using: &rng) == 0,
                transferID: Int.random(in: 0..<10, using: &rng) == 0 ? "xfer" : nil,
                accountOffBudget: Int.random(in: 0..<10, using: &rng) == 0
            )
        }
        let rows = (0..<rowCount).map { index in
            let day = Int.random(in: -4..<66, using: &rng)
            return TransactionCSVImportRow(
                id: "r-\(index)",
                sourceLine: index + 1,
                dateText: dayText(day),
                date: Date(timeIntervalSince1970: Double(19_900 + day) * 86_400 + 43_200),
                amountMinorUnits: pick(amounts),
                payeeName: pick(["Alpha", "BETA", "Gamma", "To Savings", "Unknown", ""]),
                notes: pick([nil, "note", "other"]),
                categoryName: pick([nil, "Groceries", "Dining", "Nope"]),
                cleared: pick([nil, true, false]),
                importedID: Int.random(in: 0..<5, using: &rng) == 0 ? "imp-\(Int.random(in: 0..<7, using: &rng))" : nil
            )
        }
        return (rows, candidates)
    }

    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 6, 7, 8])
    func indexedMatchMatchesTheNaiveMatcher(seed: UInt64) {
        let data = Self.fixture(seed: seed, rowCount: 120, candidateCount: 300)
        let expected = Self.naiveMatch(rows: data.rows, candidates: data.candidates)
        let actual = TransactionCSVImportMatcher.match(rows: data.rows, candidates: data.candidates, context: Self.context)
        #expect(actual == expected, "seed \(seed)")
        // The fixture reaches every disposition kind, including the 1.6 rules.
        var kinds: Set<String> = []
        for disposition in actual {
            switch disposition {
            case .insert(let isTransfer): kinds.insert(isTransfer ? "insertTransfer" : "insert")
            case .update: kinds.insert("update")
            case .ignored: kinds.insert("ignored")
            case .skippedReconciled: kinds.insert("skippedReconciled")
            }
        }
        #expect(kinds.isSuperset(of: ["update", "skippedReconciled"]), "seed \(seed) \(kinds)")
    }

    @Test func scopedFetchMatchesTheUnboundedFetch() async throws {
        var sql = """
            ALTER TABLE transactions ADD COLUMN description TEXT;
            ALTER TABLE transactions ADD COLUMN notes TEXT;
            ALTER TABLE transactions ADD COLUMN cleared INTEGER;
            ALTER TABLE transactions ADD COLUMN isChild INTEGER;
            ALTER TABLE transactions ADD COLUMN financial_id TEXT;
            ALTER TABLE transactions ADD COLUMN imported_description TEXT;
            DELETE FROM transactions;
            """
        var rng = SplitMix64(seed: 77)
        for index in 0..<400 {
            let day = Int.random(in: 0..<1_200, using: &rng)
            let compact = Self.dayText(day).replacingOccurrences(of: "-", with: "")
            let imported = Int.random(in: 0..<20, using: &rng) == 0 ? "'bank-\(Int.random(in: 0..<30, using: &rng))'" : "NULL"
            sql += "INSERT INTO transactions (id, acct, date, amount, tombstone, parent_id, is_parent, isChild, financial_id) VALUES ('t-\(index)', 'checking', \(compact), \(Int.random(in: -3...3, using: &rng) * 500), 0, NULL, 0, 0, \(imported));\n"
        }
        let database = try BudgetDatabase(databaseURL: fixtures.makeSQLiteFixture(extraSQL: sql))
        let everything = TransactionCSVImportMatcher.CandidateScope(
            dateWindow: (from: "0001-01-01", to: "9999-12-31"), importedIDs: [])
        let all = try await database.fetchTransactionCSVImportCandidates(accountID: "checking", scope: everything)
        #expect(all.count == 400)

        var totalScoped = 0
        for seed in UInt64(1)...6 {
            var data = Self.fixture(seed: seed, rowCount: 30, candidateCount: 0)
            // Rows cluster inside a three-week span; some carry imported IDs.
            data.rows = data.rows.enumerated().map { index, row in
                let day = 300 + Int.random(in: 0..<21, using: &rng)
                return TransactionCSVImportRow(
                    id: row.id, sourceLine: row.sourceLine, dateText: Self.dayText(day), date: row.date,
                    amountMinorUnits: [-1_500, -500, 0, 500, 1_000][index % 5], payeeName: "",
                    notes: nil, categoryName: nil, cleared: nil,
                    importedID: index % 6 == 0 ? "bank-\(index % 30)" : nil
                )
            }
            let scope = TransactionCSVImportMatcher.candidateScope(rows: data.rows)
            let scoped = try await database.fetchTransactionCSVImportCandidates(accountID: "checking", scope: scope)
            totalScoped += scoped.count
            let expected = TransactionCSVImportMatcher.match(rows: data.rows, candidates: all, context: Self.context)
            let actual = TransactionCSVImportMatcher.match(rows: data.rows, candidates: scoped, context: Self.context)
            #expect(actual == expected, "seed \(seed)")
            #expect(expected == Self.naiveMatch(rows: data.rows, candidates: all))
            // Work count: bounded rows, not the table.
            #expect(scoped.count < all.count / 2, "seed \(seed): \(scoped.count) of \(all.count)")
        }
        #expect(totalScoped > 0)
    }

    @Test func candidateScopeWidensByTheFuzzyWindowAndIgnoresBadDates() {
        let data = Self.fixture(seed: 1, rowCount: 3, candidateCount: 0)
        let rows = zip(data.rows, ["2026-03-10", "2026-03-20", "2026-02-30"]).map { row, day in
            TransactionCSVImportRow(
                id: row.id, sourceLine: row.sourceLine, dateText: day, date: row.date,
                amountMinorUnits: 1, payeeName: "", notes: nil, categoryName: nil, cleared: nil,
                importedID: row.id == "r-0" ? "x" : ""
            )
        }
        let scope = TransactionCSVImportMatcher.candidateScope(rows: rows)
        #expect(scope.dateWindow?.from == "2026-03-03")
        #expect(scope.dateWindow?.to == "2026-03-27")
        #expect(scope.importedIDs == ["x"])
        #expect(TransactionCSVImportMatcher.candidateScope(rows: []).dateWindow == nil)
    }
}
