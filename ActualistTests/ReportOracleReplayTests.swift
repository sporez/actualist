import Foundation
import Testing
@testable import Actualist

/// Replays the Reports oracle contract through the production report reads (the dashboard cards and
/// the explorer) for net worth, cash flow, spending and the transaction calendar. One replay test
/// covers every case id; the partition test accounts for the manifest. The mapping rules (sign,
/// budget rounding, 28 buckets, values after today) and the compared fields are documented in
/// `ReportOracleReplaySupport.swift` and `scripts/report-parity/README.md`.
@MainActor
struct ReportOracleReplayTests {
    private static let domain = "Reports"
    private static let fileName = "reports-contract.json"

    /// Read by the `@Test(arguments:)` macro outside the suite's main-actor isolation.
    nonisolated private static let replayedCaseIDs = [
        "nw-monthly-open",
        "nw-monthly-ui",
        "nw-monthly-onbudget",
        "nw-daily-ui",
        "nw-monthly-early-start",
        "nw-daily-ui-late",
        "cf-monthly",
        "cf-daily",
        "cf-monthly-checking",
        "cf-daily-late",
        "sp-single-sep",
        "sp-single-jul",
        "sp-budget-envelope-sep",
        "sp-budget-envelope-aug",
        "sp-budget-tracking-sep",
        "sp-budget-tracking-aug",
        "sp-average-sep",
        "sp-condition-category",
        "sp-condition-account",
        "sp-single-sep-late",
        "cal-default",
        "cal-first-day-1",
        "cal-first-day-invalid",
        "cal-no-transfers",
        "cal-default-late",
    ]

    @Test(arguments: replayedCaseIDs)
    func replaysReportCase(caseID: String) async throws {
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "expected")
        let entry = try cases.entry(caseID)
        let worlds = try ReportOracleReplay.worlds(domain: Self.domain, fileName: Self.fileName)
        let actual = try await ReportOracleReplay.replay(entry: entry, worlds: worlds)
        let expected = try ReportOracleReplay.expected(entry)
        var comparison = OracleComparison()
        comparison.compare(expected: expected, actual: actual)
        // Array-size mismatches name only the counts, so a failure also carries both whole values.
        let values = "\nexpected \(expected.canonical)\nactual \(actual.canonical)"
        #expect(comparison.mismatches.isEmpty, Comment(rawValue: OracleComparison.report(caseID, comparison.mismatches) + values))
    }

    @Test func partitionsEveryReportFixtureCase() throws {
        let manifest = try OracleManifest(
            domain: Self.domain,
            manifestName: "reports-manifest.json",
            fileName: Self.fileName
        )
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "expected")
        let problems = manifest.partitionProblems(fixtureIDs: cases.ids, replayed: Self.replayedCaseIDs)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "; ")))
    }
}
