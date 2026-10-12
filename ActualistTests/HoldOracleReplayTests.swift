import Foundation
import Testing
@testable import Actualist

/// Replays the Hold oracle contract through the production hold path. One replay test covers every
/// replayed case id; the partition test accounts for the rest.
@MainActor
struct HoldOracleReplayTests {
    private static let fileName = "hold-contract.json"
    private static let manifestName = "hold-manifest.json"

    /// Read by the `@Test(arguments:)` macro outside the suite's main-actor isolation.
    nonisolated private static let replayedCaseIDs = [
        "hold-partial-then-repeat-adds",
        "hold-full-available-to-budget",
        "hold-more-than-available-clamps",
        "hold-repeat-clamps-to-remaining-to-budget",
        "release-hold-restores-to-budget",
        "release-without-stored-hold-row-writes-zero-hold",
        "hold-after-release-starts-from-zero",
        "hold-rolls-into-next-month-available",
        "hold-across-year-boundary-rolls-into-january",
        "hold-noop-when-to-budget-is-zero",
        "hold-noop-when-to-budget-is-negative",
        "release-manual-hold-reveals-automatic-income-hold",
        "hold-in-future-month-creates-stored-row",
        "actualist-compatible-crdt-replays-into-actual-peer",
    ]

    @Test
    func manifestPartitionsEveryContractCase() throws {
        let cases = try OracleFixtureCases(domain: "Holds", fileName: Self.fileName, outputKey: "steps")
        let manifest = try OracleManifest(domain: "Holds", manifestName: Self.manifestName, fileName: Self.fileName)
        let problems = manifest.partitionProblems(fixtureIDs: cases.ids, replayed: Self.replayedCaseIDs)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test(arguments: replayedCaseIDs)
    func replaysHoldCase(caseID: String) async throws {
        let cases = try OracleFixtureCases(domain: "Holds", fileName: Self.fileName, outputKey: "steps")
        let replay = try await HoldOracleReplay.replay(try cases.entry(caseID))
        var comparison = OracleComparison()
        comparison.compare(expected: .object(replay.expected), actual: .object(replay.actual))

        #expect(
            comparison.mismatches.isEmpty,
            Comment(rawValue: OracleComparison.report(caseID, comparison.mismatches))
        )
    }
}
