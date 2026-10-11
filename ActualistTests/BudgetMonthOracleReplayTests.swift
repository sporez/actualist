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

    /// Cases that must show each registered divergence (`config/parity/known-divergences.json`). A listed case
    /// that stops showing its divergence fails as a stale marker, and an unlisted case that shows one fails
    /// strictly.
    private static let op26CaseIDs: Set<String> = [
        "cover-clamped-to-source-leftover",
        "generated-001-2026-11",
        "generated-003-2026-11",
        "generated-004-2027-11",
        "generated-008-2027-11",
        "generated-011-2026-11",
        "generated-012-2027-11",
        "generated-014-2027-11",
        "generated-018-2027-11",
        "generated-024-2027-11",
        "generated-025-2026-11",
        "generated-027-2026-11",
        "generated-037-2026-11",
        "generated-039-2026-11",
        "generated-040-2027-11",
        "generated-043-2026-11",
        "generated-053-2026-11",
        "generated-056-2027-11",
        "generated-057-2026-11",
        "generated-058-2027-11",
        "generated-059-2026-11",
        "transfer-available-clamped-to-to-budget",
    ]

    private static let op27CaseIDs: Set<String> = [
        "generated-004-2027-11",
        "generated-021-2026-11",
        "generated-027-2026-11",
        "generated-029-2026-11",
        "generated-037-2026-11",
        "generated-038-2027-11",
        "generated-044-2027-11",
        "generated-057-2026-11",
    ]

    private static let op28CaseIDs: Set<String> = [
        "assign-overbudgets-and-hold-refused",
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
        "generated-014-2027-11",
        "generated-015-2026-11",
        "generated-016-2027-11",
        "generated-017-2026-11",
        "generated-018-2027-11",
        "generated-019-2026-11",
        "generated-020-2027-11",
        "generated-021-2026-11",
        "generated-022-2027-11",
        "generated-024-2027-11",
        "generated-025-2026-11",
        "generated-026-2027-11",
        "generated-027-2026-11",
        "generated-028-2027-11",
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
        "generated-042-2027-11",
        "generated-043-2026-11",
        "generated-044-2027-11",
        "generated-047-2026-11",
        "generated-049-2026-11",
        "generated-050-2027-11",
        "generated-051-2026-11",
        "generated-052-2027-11",
        "generated-053-2026-11",
        "generated-054-2027-11",
        "generated-055-2026-11",
        "generated-056-2027-11",
        "generated-057-2026-11",
        "generated-058-2027-11",
        "generated-059-2026-11",
        "generated-060-2027-11",
        "hidden-category-overspent-counts",
        "income-category-carryover-holds-next-month",
        "leap-day-2028-counts-in-sum",
        "move-creates-overspend",
        "offbudget-and-uncategorized-excluded",
        "overspend-carries-negative-with-carryover",
        "overspend-resets-without-carryover",
        "positive-balance-carries-without-rollover",
        "rollover-all-expense-equals-per-category-toggles",
        "tracking-assign-to-income-category",
        "tracking-carryover-chain-no-positive-clamp",
        "transfer-available-clamped-to-to-budget",
        "year-end-hold-and-overspend-roll-into-january",
    ]

    private static let op29CaseIDs: Set<String> = [
        "cover-clamped-to-source-leftover",
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
        "generated-014-2027-11",
        "generated-015-2026-11",
        "generated-016-2027-11",
        "generated-017-2026-11",
        "generated-018-2027-11",
        "generated-019-2026-11",
        "generated-020-2027-11",
        "generated-021-2026-11",
        "generated-022-2027-11",
        "generated-024-2027-11",
        "generated-025-2026-11",
        "generated-026-2027-11",
        "generated-027-2026-11",
        "generated-028-2027-11",
        "generated-029-2026-11",
        "generated-030-2027-11",
        "generated-031-2026-11",
        "generated-032-2027-11",
        "generated-033-2026-11",
        "generated-034-2027-11",
        "generated-035-2026-11",
        "generated-036-2027-11",
        "generated-037-2026-11",
        "generated-038-2027-11",
        "generated-039-2026-11",
        "generated-040-2027-11",
        "generated-041-2026-11",
        "generated-043-2026-11",
        "generated-044-2027-11",
        "generated-045-2026-11",
        "generated-047-2026-11",
        "generated-049-2026-11",
        "generated-050-2027-11",
        "generated-051-2026-11",
        "generated-052-2027-11",
        "generated-053-2026-11",
        "generated-054-2027-11",
        "generated-055-2026-11",
        "generated-056-2027-11",
        "generated-057-2026-11",
        "generated-058-2027-11",
        "generated-059-2026-11",
        "generated-060-2027-11",
        "income-category-carryover-holds-next-month",
        "move-creates-overspend",
        "move-to-to-budget",
        "overspend-carries-negative-with-carryover",
        "rollover-all-expense-equals-per-category-toggles",
        "tracking-carryover-chain-no-positive-clamp",
        "year-end-hold-and-overspend-roll-into-january",
    ]

    private static let op30CaseIDs: Set<String> = [
        "generated-001-2026-11",
        "generated-002-2027-11",
        "generated-003-2026-11",
        "generated-004-2027-11",
        "generated-005-2026-11",
        "generated-006-2027-11",
        "generated-007-2026-11",
        "generated-009-2026-11",
        "generated-010-2027-11",
        "generated-012-2027-11",
        "generated-013-2026-11",
        "generated-014-2027-11",
        "generated-015-2026-11",
        "generated-016-2027-11",
        "generated-017-2026-11",
        "generated-020-2027-11",
        "generated-022-2027-11",
        "generated-026-2027-11",
        "generated-028-2027-11",
        "generated-029-2026-11",
        "generated-030-2027-11",
        "generated-031-2026-11",
        "generated-032-2027-11",
        "generated-033-2026-11",
        "generated-034-2027-11",
        "generated-035-2026-11",
        "generated-036-2027-11",
        "generated-037-2026-11",
        "generated-038-2027-11",
        "generated-039-2026-11",
        "generated-040-2027-11",
        "generated-041-2026-11",
        "generated-042-2027-11",
        "generated-044-2027-11",
        "generated-047-2026-11",
        "generated-049-2026-11",
        "generated-050-2027-11",
        "generated-051-2026-11",
        "generated-052-2027-11",
        "generated-053-2026-11",
        "generated-054-2027-11",
        "generated-055-2026-11",
        "generated-056-2027-11",
        "generated-057-2026-11",
        "generated-058-2027-11",
        "generated-060-2027-11",
        "hold-reduces-to-budget-and-arrives-next-month",
        "income-category-carryover-holds-next-month",
        "overspend-carries-negative-with-carryover",
        "rollover-all-expense-equals-per-category-toggles",
        "tracking-carryover-chain-no-positive-clamp",
        "year-end-hold-and-overspend-roll-into-january",
    ]

    private static let op31CaseIDs: Set<String> = [
        "generated-004-2027-11",
        "generated-008-2027-11",
        "generated-012-2027-11",
        "generated-015-2026-11",
        "generated-019-2026-11",
        "generated-024-2027-11",
        "generated-025-2026-11",
        "generated-026-2027-11",
        "generated-030-2027-11",
        "generated-039-2026-11",
        "generated-043-2026-11",
        "generated-057-2026-11",
    ]

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

    private static let op33CaseIDs: Set<String> = [
        "generated-016-2027-11",
        "generated-029-2026-11",
    ]

    private static let op34CaseIDs: Set<String> = [
        "generated-034-2027-11",
    ]

    /// Cases whose oracle `last-month-overspent` is nonzero (Actualist exposes 0). Derived from the oracle contract
    /// by a local, uncommitted mirror and confirmed by the stale-marker check.
    private static let op35CaseIDs: Set<String> = [
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
        "generated-014-2027-11",
        "generated-015-2026-11",
        "generated-016-2027-11",
        "generated-017-2026-11",
        "generated-018-2027-11",
        "generated-019-2026-11",
        "generated-020-2027-11",
        "generated-021-2026-11",
        "generated-022-2027-11",
        "generated-023-2026-11",
        "generated-024-2027-11",
        "generated-025-2026-11",
        "generated-026-2027-11",
        "generated-027-2026-11",
        "generated-028-2027-11",
        "generated-029-2026-11",
        "generated-030-2027-11",
        "generated-031-2026-11",
        "generated-032-2027-11",
        "generated-033-2026-11",
        "generated-034-2027-11",
        "generated-035-2026-11",
        "generated-036-2027-11",
        "generated-037-2026-11",
        "generated-038-2027-11",
        "generated-039-2026-11",
        "generated-040-2027-11",
        "generated-041-2026-11",
        "generated-042-2027-11",
        "generated-043-2026-11",
        "generated-044-2027-11",
        "generated-045-2026-11",
        "generated-046-2027-11",
        "generated-047-2026-11",
        "generated-048-2027-11",
        "generated-049-2026-11",
        "generated-050-2027-11",
        "generated-051-2026-11",
        "generated-052-2027-11",
        "generated-053-2026-11",
        "generated-054-2027-11",
        "generated-055-2026-11",
        "generated-056-2027-11",
        "generated-057-2026-11",
        "generated-058-2027-11",
        "generated-059-2026-11",
        "generated-060-2027-11",
        "hidden-category-overspent-counts",
        "leap-day-2028-counts-in-sum",
        "move-creates-overspend",
        "overspend-carries-negative-with-carryover",
        "overspend-resets-without-carryover",
        "year-end-hold-and-overspend-roll-into-january",
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

        let op26 = split.mismatches(for: .op26)
        if Self.op26CaseIDs.contains(caseID) {
            withKnownIssue("OP-26: a cover or transfer-available moves the requested amount without the source clamp the pinned Actual applies") {
                #expect(op26.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op26)))
            }
        } else {
            #expect(op26.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op26)))
        }

        let op27 = split.mismatches(for: .op27)
        if Self.op27CaseIDs.contains(caseID) {
            withKnownIssue("OP-27: a move to or from To Budget writes no <month>-to-budget row, where the pinned Actual writes one") {
                #expect(op27.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op27)))
            }
        } else {
            #expect(op27.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op27)))
        }

        let op28 = split.mismatches(for: .op28)
        if Self.op28CaseIDs.contains(caseID) {
            withKnownIssue("OP-28: a new assign or move row writes carryover = false, where the pinned Actual writes no carryover cell") {
                #expect(op28.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op28)))
            }
        } else {
            #expect(op28.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op28)))
        }

        let op29 = split.mismatches(for: .op29)
        if Self.op29CaseIDs.contains(caseID) {
            withKnownIssue("OP-29: an existing budget row is rewritten with its category or month cell, where the pinned Actual writes none") {
                #expect(op29.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op29)))
            }
        } else {
            #expect(op29.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op29)))
        }

        let op30 = split.mismatches(for: .op30)
        if Self.op30CaseIDs.contains(caseID) {
            withKnownIssue("OP-30: a new budget row's month identity is written as a number, where the pinned Actual writes text") {
                #expect(op30.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op30)))
            }
        } else {
            #expect(op30.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op30)))
        }

        let op31 = split.mismatches(for: .op31)
        if Self.op31CaseIDs.contains(caseID) {
            withKnownIssue("OP-31: a reset-hold with no stored hold writes no buffered = 0 row, where the pinned Actual writes it") {
                #expect(op31.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op31)))
            }
        } else {
            #expect(op31.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op31)))
        }

        let op32 = split.mismatches(for: .op32)
        if Self.op32CaseIDs.contains(caseID) {
            withKnownIssue("OP-32: a move or cover writes no Reassigned month note, where the pinned Actual writes one") {
                #expect(op32.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op32)))
            }
        } else {
            #expect(op32.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op32)))
        }

        let op33 = split.mismatches(for: .op33)
        if Self.op33CaseIDs.contains(caseID) {
            withKnownIssue("OP-33: a set-carryover stops at a wall-clock horizon, where the pinned Actual stops at the budget's last month") {
                #expect(op33.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op33)))
            }
        } else {
            #expect(op33.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op33)))
        }

        let op34 = split.mismatches(for: .op34)
        if Self.op34CaseIDs.contains(caseID) {
            withKnownIssue("OP-34: a hold is refused while the automatic income-carryover hold is active, where the pinned Actual commits the reset and the hold") {
                #expect(op34.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op34)))
            }
        } else {
            #expect(op34.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op34)))
        }

        let op35 = split.mismatches(for: .op35)
        if Self.op35CaseIDs.contains(caseID) {
            withKnownIssue("OP-35: the month's last-month overspend is exposed as 0, where the pinned Actual exposes last month's overspend") {
                #expect(op35.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op35)))
            }
        } else {
            #expect(op35.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op35)))
        }
    }
}
