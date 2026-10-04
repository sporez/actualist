import Foundation
import Testing
@testable import Actualist

/// Phase 5: the fuzzy dataset parses each row's day once. The previous
/// per-pair `dayDistance` filter and sort is the oracle.
struct BankSyncFuzzyDatasetEquivalenceTests {
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private static func oracle(
        for candidate: BankSyncReconciliation.Candidate, in existing: [BankSyncReconciliation.Existing]
    ) -> [BankSyncReconciliation.Existing] {
        existing
            .filter { row in
                row.isValidCandidate
                    && row.amountMinorUnits == candidate.amountMinorUnits
                    && abs(BankSyncReconciliation.dayDistance(row.dayID, candidate.dayID)) <= 7
            }
            .enumerated()
            .sorted {
                let left = abs(BankSyncReconciliation.dayDistance($0.element.dayID, candidate.dayID))
                let right = abs(BankSyncReconciliation.dayDistance($1.element.dayID, candidate.dayID))
                if left != right { return left < right }
                return $0.offset < $1.offset
            }
            .map(\.element)
    }

    @Test func epochDayDatasetMatchesThePerPairDistanceOracleOnRandomizedInputs() {
        var rng = SeededGenerator(state: 42)
        let days = ["20240225", "20240228", "20240229", "20240301", "20240304", "20240307", "20240308",
                    "20240310", "20231231", "20240101", "20240230", "20260229", "bad", "", "2024030"]
        let amounts = [-1_000, -2_000, 500]
        var nonTrivial = 0
        for _ in 0..<200 {
            let existing: [BankSyncReconciliation.Existing] = (0..<Int.random(in: 0..<14, using: &rng)).map { index in
                let isChild = Bool.random(using: &rng)
                return BankSyncReconciliation.Existing(
                    id: "e\(index)", financialID: nil, dayID: days.randomElement(using: &rng)!,
                    amountMinorUnits: amounts.randomElement(using: &rng)!, payeeID: nil, categoryID: nil,
                    notes: nil, cleared: false, reconciled: false, importedPayee: nil, isParent: false,
                    isChild: isChild, parentID: isChild && Bool.random(using: &rng) ? "p" : nil, transferID: nil)
            }
            let epochDays = existing.map { BankSyncReconciliation.epochDay(compact: $0.dayID) }
            for day in days {
                let candidate = BankSyncReconciliation.Candidate(
                    financialID: nil, dayID: day, amountMinorUnits: amounts.randomElement(using: &rng)!,
                    payeeID: nil, payeeName: nil, notes: nil, categoryID: nil, cleared: false, importedPayee: nil)
                let expected = Self.oracle(for: candidate, in: existing)
                #expect(BankSyncReconciliation.fuzzyDataset(for: candidate, in: existing, epochDays: epochDays)
                    .map(\.id) == expected.map(\.id))
                if expected.count > 1 { nonTrivial += 1 }
            }
        }
        #expect(nonTrivial > 50)
    }
}
