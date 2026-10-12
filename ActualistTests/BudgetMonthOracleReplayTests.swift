import Foundation
import Testing
@testable import Actualist

/// Replays the BudgetMonth oracle contract through the production budget write seams and reads. The
/// partition test accounts for every manifest case; the replay test compares each case step by step.
/// See `scripts/budget-month-parity/README.md` for the field map and the upstream-only fields.
@MainActor
struct BudgetMonthOracleReplayTests {
    private static let fileName = "budget-month-contract.json"
    private static let manifestName = "budget-month-manifest.json"

    /// Read by the `@Test(arguments:)` macro outside the suite's main-actor isolation.
    nonisolated private static let namedCaseIDs = [
        "overspend-resets-without-carryover",
        "overspend-carries-negative-with-carryover",
        "positive-balance-carries-without-rollover",
        "hidden-category-overspent-counts",
        "hold-reduces-to-budget-and-arrives-next-month",
        "cover-overspending-from-to-budget",
        "cover-clamped-to-source-leftover",
        "cover-partial-amount",
        "move-creates-overspend",
        "move-to-to-budget",
        "transfer-available-clamped-to-to-budget",
        "assign-overbudgets-and-hold-refused",
        "income-category-carryover-holds-next-month",
        "reset-income-carryover-clears-automatic-hold",
        "rollover-all-expense-equals-per-category-toggles",
        "year-end-hold-and-overspend-roll-into-january",
        "leap-day-2028-counts-in-sum",
        "offbudget-and-uncategorized-excluded",
        "tracking-assign-to-income-category",
        "tracking-carryover-chain-no-positive-clamp",
    ]

    /// The 60 generated cases, numbered 001 to 060. Odd numbers end in 2026-11 and even in 2027-11.
    /// The partition test checks this list against the manifest.
    nonisolated private static let replayedCaseIDs: [String] = namedCaseIDs + (1...60).map { number in
        "generated-\(String(format: "%03d", number))-\(number % 2 == 1 ? "2026-11" : "2027-11")"
    }

    @Test
    func manifestPartitionsEveryContractCase() throws {
        let cases = try OracleFixtureCases(domain: "BudgetMonth", fileName: Self.fileName, outputKey: "expected")
        let manifest = try OracleManifest(domain: "BudgetMonth", manifestName: Self.manifestName, fileName: Self.fileName)
        let problems = manifest.partitionProblems(fixtureIDs: cases.ids, replayed: Self.replayedCaseIDs)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    /// Cases that must show OP-32, the one intended divergence (`config/parity/known-divergences.json`). A listed
    /// case that stops showing it fails as a stale marker, and an unlisted case that shows it fails strictly.
    private static let op32CaseIDs: Set<String> = [
        "cover-clamped-to-source-leftover",
        "cover-overspending-from-to-budget",
        "cover-partial-amount",
        "generated-001-2026-11",
        "generated-002-2027-11",
        "generated-003-2026-11",
        "generated-004-2027-11",
        "generated-005-2026-11",
        "generated-006-2027-11",
        "generated-007-2026-11",
        "generated-008-2027-11",
        "generated-009-2026-11",
        "generated-010-2027-11",
        "generated-011-2026-11",
        "generated-012-2027-11",
        "generated-013-2026-11",
        "generated-015-2026-11",
        "generated-016-2027-11",
        "generated-017-2026-11",
        "generated-018-2027-11",
        "generated-019-2026-11",
        "generated-020-2027-11",
        "generated-021-2026-11",
        "generated-022-2027-11",
        "generated-025-2026-11",
        "generated-026-2027-11",
        "generated-027-2026-11",
        "generated-029-2026-11",
        "generated-030-2027-11",
        "generated-031-2026-11",
        "generated-032-2027-11",
        "generated-034-2027-11",
        "generated-035-2026-11",
        "generated-036-2027-11",
        "generated-037-2026-11",
        "generated-038-2027-11",
        "generated-039-2026-11",
        "generated-040-2027-11",
        "generated-044-2027-11",
        "generated-045-2026-11",
        "generated-047-2026-11",
        "generated-049-2026-11",
        "generated-050-2027-11",
        "generated-052-2027-11",
        "generated-053-2026-11",
        "generated-055-2026-11",
        "generated-056-2027-11",
        "generated-057-2026-11",
        "generated-059-2026-11",
        "generated-060-2027-11",
        "move-creates-overspend",
        "move-to-to-budget",
    ]

    @Test(arguments: replayedCaseIDs)
    func replaysBudgetMonthCase(caseID: String) async throws {
        let cases = try OracleFixtureCases(domain: "BudgetMonth", fileName: Self.fileName, outputKey: "expected")
        let entry = try cases.entry(caseID)
        let seed = String(describing: entry["seed"] ?? "none")
        let replay = try await BudgetMonthOracleReplay.replay(entry)
        let split = BudgetMonthDivergenceSplit(replay.mismatches, stepLabels: replay.stepLabels)
        let counts = BudgetMonthDivergence.allCases
            .map { "\($0.rawValue)=\(split.mismatches(for: $0).count)" }
            .joined(separator: " ")
        let summary = ["BMSPLIT \(caseID) \(counts) unclassified=\(split.unclassified.count)",
                       "SEAM \(caseID) \(replay.seamGap ?? "none")",
                       "REFUSALS \(caseID) \(replay.refusals.count)"]
            + replay.overspentStates.map { "\(caseID) last-month-overspent: \($0)" }
        Attachment.record(summary.joined(separator: "\n"), named: "\(caseID)-split.txt")

        let refusals = replay.refusals.map { "\(caseID) refused: \($0)" }
        let seamGap = replay.seamGap.map { "\(caseID) seam gap, replay stopped: \($0)" }
        let context = (["\(caseID) seed \(seed)"] + refusals + [seamGap ?? ""])
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        #expect(
            split.unclassified.isEmpty,
            Comment(rawValue: context + "\n" + OracleComparison.report(caseID, split.unclassified))
        )

        let op32 = split.mismatches(for: .op32)
        if Self.op32CaseIDs.contains(caseID) {
            withKnownIssue("OP-32: a move or cover writes no Reassigned month note, where the pinned Actual writes one") {
                #expect(op32.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op32)))
            }
        } else {
            #expect(op32.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op32)))
        }
    }
}
