import Foundation
import Testing
@testable import Actualist

/// Replays the Apply Templates oracle contract through the production apply path. Test A runs each
/// case as the fixture states it. Test B seeds each note-only definition from the oracle first, so
/// the apply engine runs on its own; see the README's "Two replays" section. The partition test
/// accounts for every case.
@MainActor
struct TemplateApplyOracleReplayTests {
    private static let fileName = "template-apply-contract.json"
    private static let manifestName = "template-apply-manifest.json"
    /// Its stored definition is stale against the note, so production refuses the apply (OP-25).
    private static let staleRefusalCaseID = "tapply-named-stale-note-goal-def"

    /// Read by the `@Test(arguments:)` macro outside the suite's main-actor isolation.
    nonisolated private static let replayedCaseIDs = [
        "tapply-named-ended-schedule",
        "tapply-named-deleted-category",
        "tapply-named-priority-clamp",
        "tapply-named-average-missing-months",
        "tapply-named-yearly-sinking-fund",
        "tapply-named-schedule-by-id",
        "tapply-named-stale-note-goal-def",
        "tapply-named-tracking-budget",
        "tapply-named-jpy-currency",
        "tapply-named-leap-year-periodic",
        "tapply-named-year-boundary-by",
        "tapply-named-overwrite-existing-budget",
        "tapply-named-apply-skips-budgeted",
        "tapply-named-no-templates",
        "tapply-named-orphan-goal-reset",
        "tapply-generated-fixed-above-1",
        "tapply-generated-fixed-above-2",
        "tapply-generated-fixed-above-3",
        "tapply-generated-fixed-below-1",
        "tapply-generated-fixed-below-2",
        "tapply-generated-fixed-below-3",
        "tapply-generated-fixed-exact-1",
        "tapply-generated-fixed-exact-2",
        "tapply-generated-fixed-exact-3",
        "tapply-generated-fixed-zero-1",
        "tapply-generated-fixed-zero-2",
        "tapply-generated-fixed-zero-3",
        "tapply-generated-fixed-negative-1",
        "tapply-generated-fixed-negative-2",
        "tapply-generated-fixed-negative-3",
        "tapply-generated-priority-above-1",
        "tapply-generated-priority-above-2",
        "tapply-generated-priority-above-3",
        "tapply-generated-priority-below-1",
        "tapply-generated-priority-below-2",
        "tapply-generated-priority-below-3",
        "tapply-generated-priority-exact-1",
        "tapply-generated-priority-exact-2",
        "tapply-generated-priority-exact-3",
        "tapply-generated-priority-zero-1",
        "tapply-generated-priority-zero-2",
        "tapply-generated-priority-zero-3",
        "tapply-generated-priority-negative-1",
        "tapply-generated-priority-negative-2",
        "tapply-generated-priority-negative-3",
        "tapply-generated-schedule-above-1",
        "tapply-generated-schedule-above-2",
        "tapply-generated-schedule-above-3",
        "tapply-generated-schedule-below-1",
        "tapply-generated-schedule-below-2",
        "tapply-generated-schedule-below-3",
        "tapply-generated-schedule-exact-1",
        "tapply-generated-schedule-exact-2",
        "tapply-generated-schedule-exact-3",
        "tapply-generated-schedule-zero-1",
        "tapply-generated-schedule-zero-2",
        "tapply-generated-schedule-zero-3",
        "tapply-generated-schedule-negative-1",
        "tapply-generated-schedule-negative-2",
        "tapply-generated-schedule-negative-3",
        "tapply-generated-average-copy-above-1",
        "tapply-generated-average-copy-above-2",
        "tapply-generated-average-copy-above-3",
        "tapply-generated-average-copy-below-1",
        "tapply-generated-average-copy-below-2",
        "tapply-generated-average-copy-below-3",
        "tapply-generated-average-copy-exact-1",
        "tapply-generated-average-copy-exact-2",
        "tapply-generated-average-copy-exact-3",
        "tapply-generated-average-copy-zero-1",
        "tapply-generated-average-copy-zero-2",
        "tapply-generated-average-copy-zero-3",
        "tapply-generated-average-copy-negative-1",
        "tapply-generated-average-copy-negative-2",
        "tapply-generated-average-copy-negative-3",
        "tapply-generated-percent-above-1",
        "tapply-generated-percent-above-2",
        "tapply-generated-percent-above-3",
        "tapply-generated-percent-below-1",
        "tapply-generated-percent-below-2",
        "tapply-generated-percent-below-3",
        "tapply-generated-percent-exact-1",
        "tapply-generated-percent-exact-2",
        "tapply-generated-percent-exact-3",
        "tapply-generated-percent-zero-1",
        "tapply-generated-percent-zero-2",
        "tapply-generated-percent-zero-3",
        "tapply-generated-percent-negative-1",
        "tapply-generated-percent-negative-2",
        "tapply-generated-percent-negative-3",
        "tapply-generated-remainder-above-1",
        "tapply-generated-remainder-above-2",
        "tapply-generated-remainder-above-3",
        "tapply-generated-remainder-below-1",
        "tapply-generated-remainder-below-2",
        "tapply-generated-remainder-below-3",
        "tapply-generated-remainder-exact-1",
        "tapply-generated-remainder-exact-2",
        "tapply-generated-remainder-exact-3",
        "tapply-generated-remainder-zero-1",
        "tapply-generated-remainder-zero-2",
        "tapply-generated-remainder-zero-3",
        "tapply-generated-remainder-negative-1",
        "tapply-generated-remainder-negative-2",
        "tapply-generated-remainder-negative-3",
        "tapply-generated-goal-by-above-1",
        "tapply-generated-goal-by-above-2",
        "tapply-generated-goal-by-above-3",
        "tapply-generated-goal-by-below-1",
        "tapply-generated-goal-by-below-2",
        "tapply-generated-goal-by-below-3",
        "tapply-generated-goal-by-exact-1",
        "tapply-generated-goal-by-exact-2",
        "tapply-generated-goal-by-exact-3",
        "tapply-generated-goal-by-zero-1",
        "tapply-generated-goal-by-zero-2",
        "tapply-generated-goal-by-zero-3",
        "tapply-generated-goal-by-negative-1",
        "tapply-generated-goal-by-negative-2",
        "tapply-generated-goal-by-negative-3",
        "tapply-generated-limit-refill-above-1",
        "tapply-generated-limit-refill-above-2",
        "tapply-generated-limit-refill-above-3",
        "tapply-generated-limit-refill-below-1",
        "tapply-generated-limit-refill-below-2",
        "tapply-generated-limit-refill-below-3",
        "tapply-generated-limit-refill-exact-1",
        "tapply-generated-limit-refill-exact-2",
        "tapply-generated-limit-refill-exact-3",
        "tapply-generated-limit-refill-zero-1",
        "tapply-generated-limit-refill-zero-2",
        "tapply-generated-limit-refill-zero-3",
        "tapply-generated-limit-refill-negative-1",
        "tapply-generated-limit-refill-negative-2",
        "tapply-generated-limit-refill-negative-3",
        "tapply-named-excluding-priority-levels",
        "tapply-named-excluding-remainder-split",
        "tapply-named-excluding-budgeted-category",
        "tapply-named-excluding-orphan-goals",
        "tapply-named-excluding-tracking-income",
        "tapply-named-excluding-fill-empty-mixed",
        "tapply-named-excluding-priority-clamp",
        "tapply-named-excluding-all-but-one",
        "tapply-named-excluding-invalid-template",
        "tapply-named-excluding-order-remainder",
        "tapply-named-excluding-order-priority-clamp",
        "tapply-generated-excluding-fixed-above-1",
        "tapply-generated-excluding-fixed-below-1",
        "tapply-generated-excluding-fixed-exact-1",
        "tapply-generated-excluding-fixed-zero-1",
        "tapply-generated-excluding-fixed-negative-1",
        "tapply-generated-excluding-priority-above-1",
        "tapply-generated-excluding-priority-below-1",
        "tapply-generated-excluding-priority-exact-1",
        "tapply-generated-excluding-priority-zero-1",
        "tapply-generated-excluding-priority-negative-1",
        "tapply-generated-excluding-remainder-above-1",
        "tapply-generated-excluding-remainder-below-1",
        "tapply-generated-excluding-remainder-exact-1",
        "tapply-generated-excluding-remainder-zero-1",
        "tapply-generated-excluding-remainder-negative-1",
        "tapply-generated-excluding-percent-above-1",
        "tapply-generated-excluding-percent-below-1",
        "tapply-generated-excluding-percent-exact-1",
        "tapply-generated-excluding-percent-zero-1",
        "tapply-generated-excluding-percent-negative-1",
    ]

    @Test
    func manifestPartitionsEveryContractCase() throws {
        let cases = try OracleFixtureCases(domain: "TemplateApply", fileName: Self.fileName, outputKey: "expected")
        let manifest = try OracleManifest(domain: "TemplateApply", manifestName: Self.manifestName, fileName: Self.fileName)
        let problems = manifest.partitionProblems(fixtureIDs: cases.ids, replayed: Self.replayedCaseIDs)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test(arguments: replayedCaseIDs)
    func replaysTemplateApplyCase(caseID: String) async throws {
        let (entry, currentMonth) = try Self.fixtureCase(caseID)
        let replay = try await TemplateApplyOracleReplay.replay(
            entry,
            currentMonth: currentMonth,
            seedGoalDefsFromOracle: false
        )
        let mismatches = ReplayComparison.mismatches(expected: replay.expected, actual: replay.actual, path: "")
        let detail = Self.detail(caseID, mismatches, refusal: replay.refusal)

        if caseID == Self.staleRefusalCaseID {
            withKnownIssue("OP-25: a stale note-managed definition refuses the whole apply; the oracle clears it and applies the rest") {
                #expect(mismatches.isEmpty, Comment(rawValue: detail))
            }
        } else if try TemplateApplyOracleReplay.hasNoteOnlyTemplate(entry) {
            withKnownIssue("OP-24: a note-only template definition is not regenerated from its note at apply") {
                #expect(mismatches.isEmpty, Comment(rawValue: detail))
            }
        } else {
            #expect(mismatches.isEmpty, Comment(rawValue: detail))
        }
        if Self.isUpToDate(entry) {
            #expect(replay.messageCount == 0, "\(caseID) is up to date but produced \(replay.messageCount) messages")
        }
    }

    @Test(arguments: replayedCaseIDs)
    func replaysTemplateEngineWithStoredDefinitions(caseID: String) async throws {
        let (entry, currentMonth) = try Self.fixtureCase(caseID)
        let replay = try await TemplateApplyOracleReplay.replay(
            entry,
            currentMonth: currentMonth,
            seedGoalDefsFromOracle: true
        )
        let mismatches = ReplayComparison.mismatches(expected: replay.expected, actual: replay.actual, path: "")
        let detail = Self.detail(caseID, mismatches, refusal: replay.refusal)
        if caseID == Self.staleRefusalCaseID {
            withKnownIssue("OP-25: a stale note-managed definition refuses the whole apply; the oracle clears it and applies the rest") {
                #expect(mismatches.isEmpty, Comment(rawValue: detail))
            }
        } else {
            #expect(mismatches.isEmpty, Comment(rawValue: detail))
        }
    }

    /// The case object and the fixture's `currentMonth`, which every case replays against.
    private static func fixtureCase(_ caseID: String) throws -> (entry: [String: Any], currentMonth: String) {
        let cases = try OracleFixtureCases(domain: "TemplateApply", fileName: fileName, outputKey: "expected")
        return (try cases.entry(caseID), try OracleJSON.string(cases.syntheticData, "currentMonth"))
    }

    private static func isUpToDate(_ entry: [String: Any]) -> Bool {
        let notification = (entry["expected"] as? [String: Any])?["notification"] as? [String: Any]
        return notification?["message"] as? String == "templates-up-to-date"
    }

    private static func detail(_ caseID: String, _ mismatches: [ReplayMismatch], refusal: String?) -> String {
        var lines = [OracleComparison.report(caseID, mismatches)]
        if let refusal {
            lines.append("\(caseID) production refused the apply: \(refusal)")
        }
        return lines.joined(separator: "\n")
    }
}
