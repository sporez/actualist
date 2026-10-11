import Foundation
import Testing
@testable import Actualist

/// Replays the Reconciliation oracle contract through the production `BudgetDatabase` writes.
/// One replay test covers every replayed case id; the partition test accounts for the rest.
@MainActor
struct ReconciliationOracleReplayTests {
    private static let fileName = "reconciliation-contract.json"

    /// Read by the `@Test(arguments:)` macro outside the suite's main-actor isolation.
    nonisolated private static let replayedCaseIDs = [
        "cleared-balance",
        "finish",
        "lock",
        "unlock",
        "unlock-split-member",
        "unlock-split-parent",
        "unlock-split-member-unreconciled-parent",
        "unlock-simple-row",
        "adjustment-rule-delete",
        "adjustment-rule-clears-notes",
    ]

    /// Mismatch paths that a registered divergence accounts for, by fixture case. Any other path fails.
    private static let knownPaths: [String: Set<String>] = [
        "finish": ["nonzeroDifferenceError"],
        "adjustment-rule-clears-notes": ["added[0].notes"],
        "adjustment-rule-delete": ["deleted", "deletedCount"],
        "unlock-split-member": ["messages", "after.child-a", "after.child-b", "after.parent"],
    ]

    @Test(arguments: replayedCaseIDs)
    func replaysReconciliationCase(caseID: String) async throws {
        let cases = try OracleFixtureCases(domain: "Reconciliation", fileName: Self.fileName, outputKey: "value")
        let support = LocalFirstActualStoreTests()
        let input = try cases.input(caseID)
        let actual = try await ReconciliationOracleReplay.replay(
            caseID: caseID,
            input: input,
            readback: try cases.entry(caseID)["readback"] as? [String: Any],
            makeFixture: { try support.makeSQLiteFixture(extraSQL: $0) }
        )
        let expected = try ReconciliationOracleReplay.expectedValue(
            caseID,
            input: input,
            readback: try cases.entry(caseID)["readback"] as? [String: Any],
            try cases.expected(caseID)
        )
        var comparison = OracleComparison()
        comparison.compare(expected: expected, actual: actual)
        let divergence = KnownDivergenceSplit(
            comparison.mismatches,
            knownPaths: Self.knownPaths[caseID] ?? []
        )
        #expect(divergence.strict.isEmpty, Comment(rawValue: OracleComparison.report(caseID, divergence.strict)))
        switch caseID {
        case "finish":
            withKnownIssue("OP-16: a nonzero difference throws instead of locking zero transactions") {
                #expect(divergence.known.isEmpty, Comment(rawValue: OracleComparison.report(caseID, divergence.known)))
            }
        case "adjustment-rule-clears-notes":
            withKnownIssue("OP-17: a rule that clears notes still leaves the default adjustment note") {
                #expect(divergence.known.isEmpty, Comment(rawValue: OracleComparison.report(caseID, divergence.known)))
            }
        case "adjustment-rule-delete":
            withKnownIssue("OP-18: a rule that deletes the adjustment writes no tombstone") {
                #expect(divergence.known.isEmpty, Comment(rawValue: OracleComparison.report(caseID, divergence.known)))
            }
        case "unlock-split-member":
            withKnownIssue("OP-19: unlocking a split member unlocks the whole family, where Actual's child unlock is a no-op") {
                #expect(divergence.known.isEmpty, Comment(rawValue: OracleComparison.report(caseID, divergence.known)))
            }
        default:
            break
        }
    }

    @Test func partitionsEveryReconciliationFixtureCase() throws {
        let manifest = try OracleManifest(
            domain: "Reconciliation",
            manifestName: "reconciliation-manifest.json",
            fileName: Self.fileName
        )
        let cases = try OracleFixtureCases(domain: "Reconciliation", fileName: Self.fileName, outputKey: "value")
        let problems = manifest.partitionProblems(fixtureIDs: cases.ids, replayed: Self.replayedCaseIDs)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "; ")))
    }
}
