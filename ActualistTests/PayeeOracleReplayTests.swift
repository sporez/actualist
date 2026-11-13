import Foundation
import Testing
@testable import Actualist

/// Replays the Payees oracle contract through the production store's payee commands. One replay test
/// covers every case id; the partition test accounts for the manifest. The compared and excluded
/// fields are documented in `PayeeOracleReplaySupport.swift` and `scripts/payee-parity/README.md`.
/// The undo Actual recorded for each case is not replayed by this suite.
@MainActor
struct PayeeOracleReplayTests {
    private static let domain = "Payees"
    private static let fileName = "payees-contract.json"

    /// Read by the `@Test(arguments:)` macro outside the suite's main-actor isolation.
    nonisolated private static let replayedCaseIDs = [
        "read-seed",
        "create-plain",
        "create-trimmed",
        "create-case-duplicate",
        "create-diacritic-duplicate",
        "create-padded-duplicate",
        "create-account-name",
        "create-normalised-duplicate",
        "create-normalised-padded",
        "rename-plain",
        "rename-trimmed",
        "rename-unchanged",
        "rename-case-only",
        "rename-to-existing",
        "rename-empty",
        "merge-one",
        "merge-two",
        "merge-rule-referenced",
        "delete-unused",
        "delete-two-unused",
        "delete-with-transactions",
        "delete-rule-condition",
        "delete-rule-action",
        "delete-deleted-txn-only",
        "delete-mixed",
        "favorite-one",
        "unfavorite-one",
        "favorite-selection-mixed",
        "learn-off-one",
        "learn-on-one",
        "learn-selection-mixed",
        "learn-global-off",
        "learn-global-on",
    ]

    @Test(arguments: replayedCaseIDs)
    func replaysPayeeCase(caseID: String) async throws {
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "rows")
        let entry = try cases.entry(caseID)
        let actual = try await PayeeOracleReplay.replay(entry: entry, world: try Self.world())
        let expected = try PayeeOracleReplay.expected(entry)
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
            case "OP-97":
                withKnownIssue("OP-97: renaming a payee to another payee's name is refused") {
                    #expect(known.isEmpty, report)
                }
            case "OP-98":
                withKnownIssue("OP-98: payee writes skip cells whose value does not change") {
                    #expect(known.isEmpty, report)
                }
            case "OP-100":
                withKnownIssue("OP-100: the payee list is sorted differently from Actual's payees-get") {
                    #expect(known.isEmpty, report)
                }
            default:
                Issue.record("divergence \(divergence.op) has no known-issue wrapper")
            }
        }
    }

    /// Which mismatch paths a registered divergence accounts for. Anything outside them stays a
    /// strict failure, so a new difference in a marked case still fails.
    private struct Divergence {
        let op: String
        /// Path prefixes the divergence covers; empty covers every path of the case.
        let paths: [String]

        func covers(_ path: String) -> Bool {
            paths.isEmpty || paths.contains { path == $0 || path.hasPrefix($0 + "[") || path.hasPrefix($0 + ".") }
        }
    }

    private static let divergences: [String: [Divergence]] = [
        "rename-to-existing": [Divergence(op: "OP-97", paths: [])],
        "rename-unchanged": [Divergence(op: "OP-98", paths: ["writes"])],
        "favorite-selection-mixed": [Divergence(op: "OP-98", paths: ["writes"])],
        "learn-selection-mixed": [Divergence(op: "OP-98", paths: ["writes"])],
        "read-seed": [Divergence(op: "OP-100", paths: ["payees"])],
    ]

    @Test func partitionsEveryPayeeFixtureCase() throws {
        let manifest = try OracleManifest(
            domain: Self.domain,
            manifestName: "payees-manifest.json",
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
