import Foundation
import Testing
@testable import Actualist

/// Replays the AccountGroups oracle contract through the production store's account group commands and
/// the Accounts screen's grouped sections. One replay test covers every case id; the partition test
/// accounts for the manifest. The compared and excluded fields are documented in
/// `AccountGroupOracleReplaySupport.swift` and `scripts/account-group-parity/README.md`. The undo Actual
/// recorded for each case is not replayed.
@MainActor
struct AccountGroupOracleReplayTests {
    private static let domain = "AccountGroups"
    private static let fileName = "account-groups-contract.json"

    /// Read by the `@Test(arguments:)` macro outside the suite's main-actor isolation.
    nonisolated private static let replayedCaseIDs = [
        "grp-create-plain",
        "grp-create-trimmed",
        "grp-create-duplicate",
        "grp-rename-plain",
        "grp-rename-trimmed",
        "grp-rename-case-only",
        "grp-rename-unchanged",
        "grp-rename-empty",
        "grp-rename-duplicate",
        "grp-move-up",
        "grp-move-down",
        "grp-move-down-to-end",
        "grp-delete-with-accounts",
        "grp-delete-empty",
        "acct-assign",
        "acct-unassign",
        "acct-assign-same",
        "acct-assign-orphan",
        "read-groups",
        "read-tree",
    ]

    @Test(arguments: replayedCaseIDs)
    func replaysAccountGroupCase(caseID: String) async throws {
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "rows")
        let entry = try cases.entry(caseID)
        let actual = try await AccountGroupOracleReplay.replay(entry: entry, world: try Self.world())
        let expected = try AccountGroupOracleReplay.expected(entry)
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
            case "OP-111":
                withKnownIssue("OP-111: assigning an account to its current group writes nothing") {
                    #expect(known.isEmpty, report)
                }
            case "OP-112":
                withKnownIssue("OP-112: an empty account group shows in the Accounts list") {
                    #expect(known.isEmpty, report)
                }
            default:
                Issue.record("divergence \(divergence.op) has no known-issue wrapper")
            }
        }
    }

    /// Registered divergences by fixture case. Anything outside a divergence's patterns stays a strict
    /// failure, so a new difference in a marked case still fails.
    private static let divergences: [String: [OracleKnownDivergence]] = [
        "acct-assign-same": [OracleKnownDivergence(op: "OP-111", patterns: ["^writes"])],
        "read-tree": [
            OracleKnownDivergence(op: "OP-112", patterns: [#"^(onBudget|offBudget)"#]),
        ],
    ]

    @Test func partitionsEveryAccountGroupFixtureCase() throws {
        let manifest = try OracleManifest(
            domain: Self.domain,
            manifestName: "account-groups-manifest.json",
            fileName: Self.fileName
        )
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "rows")
        let problems = manifest.partitionProblems(fixtureIDs: cases.ids, replayed: Self.replayedCaseIDs)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "; ")))
    }

    /// The fixture's top-level `world`: the rows every case starts from.
    private static func world() throws -> [String: Any] {
        let url = try ParityOraclePin.fixtureURL(domain).appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OracleReplayError.missingFixture(url.path)
        }
        let root = try OracleJSON.object(OracleJSONFileCache.jsonObject(at: url), fileName)
        return try OracleJSON.object(root["world"], "world")
    }
}
