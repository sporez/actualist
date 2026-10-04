import Foundation
import GRDB
import Testing
@testable import Actualist

/// Phase 5.11: the category recurrence runs forward once from the first month
/// with real data. The naive loop from the earliest stored month is the oracle.
@MainActor
struct CategoryValueTimelineEquivalenceTests {
    private let fixtures = LocalFirstActualStoreTests()

    private static let targets = [
        "1900-01", "1900-03", "1905-01", "1950-06", "2020-06", "2024-09", "2024-10",
        "2025-03", "2025-12", "2026-06", "2026-07", "2026-12"
    ]

    private func database(seed: UInt64, tracking: Bool, early: BudgetHistoryFixture.Early) throws -> BudgetDatabase {
        try BudgetDatabase(databaseURL: fixtures.makeSQLiteFixture(
            extraSQL: BudgetHistoryFixture.sql(seed: seed, tracking: tracking, early: early)
        ))
    }

    @Test(arguments: [false, true])
    func timelineMatchesNaiveRecurrenceOnRandomizedHistory(tracking: Bool) async throws {
        var comparisons = 0
        for seed in UInt64(1)...6 {
            for early in [BudgetHistoryFixture.Early.none, .junk, .real] {
                let database = try database(seed: seed, tracking: tracking, early: early)
                let results = try await database.timelineComparisonsForTesting(targets: Self.targets)
                for result in results {
                    #expect(
                        result.production == result.naive,
                        "production seed \(seed) \(early) tracking \(tracking) \(result.target)"
                    )
                    #expect(
                        result.timeline == result.naive,
                        "timeline seed \(seed) \(early) tracking \(tracking) \(result.target)"
                    )
                    comparisons += 1
                }
            }
        }
        #expect(comparisons == 6 * 3 * Self.targets.count)
    }

    @Test func keptSnapshotsMatchTheNaiveRecurrenceMonthByMonth() async throws {
        let database = try database(seed: 9, tracking: false, early: .junk)
        let mismatches = try await database.snapshotMismatchesForTesting(
            through: "2026-12",
            keepFrom: 202409
        )
        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    @Test func recurrenceSkipsEmptyMonthsBeforeRealData() async throws {
        let database = try database(seed: 3, tracking: false, early: .junk)
        let counts = try await database.timelineMonthCountsForTesting(target: "2026-12")
        // Naive: every month from 1900-01. Bounded: from the first real month.
        #expect(counts.naive > 1_500)
        #expect(counts.timeline <= 28)
    }
}

extension BudgetDatabase {
    struct TimelineComparison {
        let target: String
        let production: String
        let naive: String
        let timeline: String
    }

    func timelineComparisonsForTesting(targets: [String]) throws -> [TimelineComparison] {
        try queue.read { db in
            let inputs = try categoryValueInputs(db: db)
            return try targets.map { target in
                func digest(
                    _ current: [String: BudgetCategoryValue],
                    _ previous: [String: BudgetCategoryValue]
                ) -> String {
                    BudgetHistoryFixture.digest(current) + " | " + BudgetHistoryFixture.digest(previous)
                }
                let production = try categoryValuesWithPrevious(through: target, db: db)
                let naive = try naiveCategoryValuesForTesting(inputs: inputs, through: target)
                let month = monthInt(target)
                let timeline = try categoryValueTimeline(inputs: inputs, through: month, keepFrom: month)
                return TimelineComparison(
                    target: target,
                    production: digest(production.current, production.previous),
                    naive: digest(naive.current, naive.previous),
                    timeline: digest(timeline.snapshots[month] ?? [:], timeline.previous)
                )
            }
        }
    }

    func snapshotMismatchesForTesting(through target: String, keepFrom: Int) throws -> [String] {
        try queue.read { db in
            let inputs = try categoryValueInputs(db: db)
            let timeline = try categoryValueTimeline(
                inputs: inputs,
                through: monthInt(target),
                keepFrom: keepFrom
            )
            var mismatches: [String] = []
            for (month, values) in timeline.snapshots.sorted(by: { $0.key < $1.key }) {
                let naive = try naiveCategoryValuesForTesting(inputs: inputs, through: monthID(month))
                if BudgetHistoryFixture.digest(values) != BudgetHistoryFixture.digest(naive.current) {
                    mismatches.append(monthID(month))
                }
            }
            return mismatches
        }
    }

    func timelineMonthCountsForTesting(target: String) throws -> (naive: Int, timeline: Int) {
        try queue.read { db in
            let inputs = try categoryValueInputs(db: db)
            let month = monthInt(target)
            return (
                try naiveCategoryValuesForTesting(inputs: inputs, through: target).monthsComputed,
                try categoryValueTimeline(inputs: inputs, through: month, keepFrom: month).monthsComputed
            )
        }
    }
}
