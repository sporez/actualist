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
        let divergences = Self.divergences[caseID] ?? []
        let strict = comparison.mismatches.filter { mismatch in
            !divergences.contains { $0.covers(mismatch.path) }
        }
        #expect(strict.isEmpty, Comment(rawValue: OracleComparison.report(caseID, strict) + values))
        for divergence in divergences {
            let known = comparison.mismatches.filter { divergence.covers($0.path) }
            let report = Comment(rawValue: OracleComparison.report(caseID, known) + values)
            switch divergence.op {
            case "OP-114":
                withKnownIssue("OP-114: a category in an income group counts as income in reports") {
                    #expect(known.isEmpty, report)
                }
            case "OP-115":
                withKnownIssue("OP-115: the tracking budget line leaves out hidden categories") {
                    #expect(known.isEmpty, report)
                }
            case "OP-116":
                withKnownIssue("OP-116: net worth doesn't align the two legs of a transfer") {
                    #expect(known.isEmpty, report)
                }
            case "OP-117":
                withKnownIssue("OP-117: monthly cash flow stops at today") {
                    #expect(known.isEmpty, report)
                }
            case "OP-118":
                withKnownIssue("OP-118: the explorer's 'no transfers' filter also drops unlinked transfer-payee rows") {
                    #expect(known.isEmpty, report)
                }
            default:
                Issue.record("divergence \(divergence.op) has no known-issue wrapper")
            }
        }
    }

    /// Registered divergences by fixture case, each scoped to the exact mismatch paths observed for it.
    /// Anything outside a divergence's patterns stays a strict failure.
    private static let divergences: [String: [OracleKnownDivergence]] = [
        "nw-monthly-open": [
            OracleKnownDivergence(op: "OP-116", patterns: [#"^(explorer\.points\[(5)\]\.balances\.acct-checking|explorer\.points\[(5)\]\.y)$"#]),
        ],
        "nw-monthly-ui": [
            OracleKnownDivergence(op: "OP-116", patterns: [#"^(dashboard\.points\[(5)\]\.y|explorer\.points\[(5)\]\.balances\.acct-checking|explorer\.points\[(5)\]\.y)$"#]),
        ],
        "nw-monthly-onbudget": [
            OracleKnownDivergence(op: "OP-116", patterns: [#"^(explorer\.points\[(5)\]\.balances\.acct-checking|explorer\.points\[(5)\]\.y)$"#]),
        ],
        "nw-daily-ui": [
            OracleKnownDivergence(op: "OP-116", patterns: [#"^(explorer\.points\[(0|1)\]\.balances\.acct-checking|explorer\.points\[(0|1)\]\.y)$"#]),
        ],
        "nw-monthly-early-start": [
            OracleKnownDivergence(op: "OP-116", patterns: [#"^(dashboard\.points\[(7)\]\.y|explorer\.points\[(7)\]\.balances\.acct-checking|explorer\.points\[(7)\]\.y)$"#]),
        ],
        "nw-daily-ui-late": [
            OracleKnownDivergence(op: "OP-116", patterns: [#"^(explorer\.points\[(0|1)\]\.balances\.acct-checking|explorer\.points\[(0|1)\]\.y)$"#]),
        ],
        "cf-monthly": [
            OracleKnownDivergence(op: "OP-117", patterns: [#"^(dashboard\.expenses|explorer\.periods\[(5)\]\.expenses|explorer\.totalExpenses)$"#]),
        ],
        "cf-monthly-checking": [
            OracleKnownDivergence(op: "OP-117", patterns: [#"^(explorer\.periods\[(5)\]\.expenses|explorer\.totalExpenses)$"#]),
        ],
        "sp-single-sep": [
            OracleKnownDivergence(op: "OP-114", patterns: [#"^(dashboard\.average\[(19|20|21|22|23|24|25|26|27)\]|dashboard\.averageCurrent\[(4|5|6|7|8|9|10|11|12|13|14)\]|dashboard\.budget\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]|dashboard\.budgetActual\[(4|5|6|7|8|9|10|11|12|13|14)\]|dashboard\.compare\[(4|5|6|7|8|9|10|11|12|13|14)\]|dashboard\.compareTo\[(21|22|23|24|25|26|27)\]|explorer\.average\[(19|20|21|22|23|24|25|26|27)\]|explorer\.budget\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]|explorer\.compare\[(4|5|6|7|8|9|10|11|12|13|14)\]|explorer\.totalTotals)$"#]),
        ],
        "sp-single-jul": [
            OracleKnownDivergence(op: "OP-114", patterns: [#"^(dashboard\.averageCurrent\[(19|20|21|22|23|24|25|26|27)\]|dashboard\.budget\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]|dashboard\.budgetActual\[(19|20|21|22|23|24|25|26|27)\]|dashboard\.compare\[(19|20|21|22|23|24|25|26|27)\]|explorer\.budget\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]|explorer\.compare\[(19|20|21|22|23|24|25|26|27)\]|explorer\.totalTotals)$"#]),
        ],
        "sp-budget-envelope-sep": [
            OracleKnownDivergence(op: "OP-114", patterns: [#"^(dashboard\.average\[(19|20|21|22|23|24|25|26|27)\]|dashboard\.averageCurrent\[(4|5|6|7|8|9|10|11|12|13|14)\]|dashboard\.budget\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]|dashboard\.budgetActual\[(4|5|6|7|8|9|10|11|12|13|14)\]|dashboard\.compare\[(4|5|6|7|8|9|10|11|12|13|14)\]|dashboard\.compareTo\[(21|22|23|24|25|26|27)\]|explorer\.average\[(19|20|21|22|23|24|25|26|27)\]|explorer\.budget\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]|explorer\.compare\[(4|5|6|7|8|9|10|11|12|13|14)\]|explorer\.totalTotals)$"#]),
        ],
        "sp-budget-envelope-aug": [
            OracleKnownDivergence(op: "OP-114", patterns: [#"^(dashboard\.average\[(19|20|21|22|23|24|25|26|27)\]|dashboard\.averageCurrent\[(21|22|23|24|25|26|27)\]|dashboard\.budget\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]|dashboard\.budgetActual\[(21|22|23|24|25|26|27)\]|dashboard\.compare\[(21|22|23|24|25|26|27)\]|dashboard\.compareTo\[(19|20|21|22|23|24|25|26|27)\]|explorer\.average\[(19|20|21|22|23|24|25|26|27)\]|explorer\.budget\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]|explorer\.compare\[(21|22|23|24|25|26|27)\]|explorer\.totalTotals)$"#]),
        ],
        "sp-budget-tracking-sep": [
            OracleKnownDivergence(op: "OP-114", patterns: [#"^(dashboard\.average\[(19|20|21|22|23|24|25|26|27)\]|dashboard\.averageCurrent\[(4|5|6|7|8|9|10|11|12|13|14)\]|dashboard\.budgetActual\[(4|5|6|7|8|9|10|11|12|13|14)\]|dashboard\.compare\[(4|5|6|7|8|9|10|11|12|13|14)\]|dashboard\.compareTo\[(21|22|23|24|25|26|27)\]|explorer\.average\[(19|20|21|22|23|24|25|26|27)\]|explorer\.compare\[(4|5|6|7|8|9|10|11|12|13|14)\]|explorer\.totalTotals|explorer\.budget\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\])$"#]),
            OracleKnownDivergence(op: "OP-115", patterns: [#"^dashboard\.budget\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]$"#]),
        ],
        "sp-budget-tracking-aug": [
            OracleKnownDivergence(op: "OP-114", patterns: [#"^(dashboard\.average\[(19|20|21|22|23|24|25|26|27)\]|dashboard\.averageCurrent\[(21|22|23|24|25|26|27)\]|dashboard\.budgetActual\[(21|22|23|24|25|26|27)\]|dashboard\.compare\[(21|22|23|24|25|26|27)\]|dashboard\.compareTo\[(19|20|21|22|23|24|25|26|27)\]|explorer\.average\[(19|20|21|22|23|24|25|26|27)\]|explorer\.compare\[(21|22|23|24|25|26|27)\]|explorer\.totalTotals|explorer\.budget\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\])$"#]),
            OracleKnownDivergence(op: "OP-115", patterns: [#"^dashboard\.budget\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]$"#]),
        ],
        "sp-average-sep": [
            OracleKnownDivergence(op: "OP-114", patterns: [#"^(dashboard\.average\[(19|20|21|22|23|24|25|26|27)\]|dashboard\.averageCurrent\[(4|5|6|7|8|9|10|11|12|13|14)\]|dashboard\.budget\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]|dashboard\.budgetActual\[(4|5|6|7|8|9|10|11|12|13|14)\]|dashboard\.compare\[(4|5|6|7|8|9|10|11|12|13|14)\]|dashboard\.compareTo\[(21|22|23|24|25|26|27)\]|explorer\.average\[(19|20|21|22|23|24|25|26|27)\]|explorer\.budget\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]|explorer\.compare\[(4|5|6|7|8|9|10|11|12|13|14)\]|explorer\.totalTotals)$"#]),
        ],
        "sp-condition-account": [
            OracleKnownDivergence(op: "OP-114", patterns: [#"^(explorer\.average\[(19|20|21|22|23|24|25|26|27)\]|explorer\.budget\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]|explorer\.compare\[(4|5|6|7|8|9|10|11|12|13|14)\]|explorer\.totalTotals)$"#]),
        ],
        "sp-single-sep-late": [
            OracleKnownDivergence(op: "OP-114", patterns: [#"^(dashboard\.average\[(19|20|21|22|23|24|25|26|27)\]|dashboard\.averageCurrent\[(4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]|dashboard\.budget\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]|dashboard\.budgetActual\[(4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]|dashboard\.compare\[(4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]|dashboard\.compareTo\[(21|22|23|24|25|26|27)\]|explorer\.average\[(19|20|21|22|23|24|25|26|27)\]|explorer\.budget\[(0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]|explorer\.compare\[(4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27)\]|explorer\.totalTotals)$"#]),
        ],
        "cal-no-transfers": [
            OracleKnownDivergence(op: "OP-118", patterns: [#"^(explorer\.days\[(55)\]\.expenses)$"#]),
        ],
    ]

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
