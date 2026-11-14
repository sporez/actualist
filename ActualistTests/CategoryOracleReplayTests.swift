import Foundation
import Testing
@testable import Actualist

/// Replays the Categories oracle contract through the production store's category and group commands.
/// One replay test covers every case id; the partition test accounts for the manifest. The compared and
/// excluded fields are documented in `CategoryOracleReplaySupport.swift` and
/// `scripts/category-parity/README.md`. The undo Actual recorded for each case is not replayed.
@MainActor
struct CategoryOracleReplayTests {
    private static let domain = "Categories"
    private static let fileName = "categories-contract.json"

    /// Read by the `@Test(arguments:)` macro outside the suite's main-actor isolation.
    nonisolated private static let replayedCaseIDs = [
        "cat-create-plain",
        "cat-create-trimmed",
        "cat-create-duplicate-case",
        "cat-create-other-group",
        "cat-create-empty-group",
        "cat-create-income",
        "grp-create-plain",
        "grp-create-trimmed",
        "grp-create-duplicate-case",
        "cat-rename-plain",
        "cat-rename-trimmed",
        "cat-rename-case-only",
        "cat-rename-unchanged",
        "cat-rename-duplicate",
        "grp-rename-plain",
        "grp-rename-duplicate",
        "cat-hide",
        "cat-unhide",
        "grp-hide",
        "grp-unhide",
        "cat-move-within",
        "cat-move-to-end",
        "cat-move-other-group",
        "cat-move-into-empty",
        "cat-move-duplicate-name",
        "grp-move-first",
        "grp-move-end",
        "cat-delete-unused",
        "cat-delete-budget-transfer",
        "cat-delete-transactions-transfer",
        "cat-delete-income-transfer",
        "grp-delete-empty",
        "grp-delete-transfer",
        "grp-delete-no-transfer",
        "read-must-transfer",
        "read-outline",
        "read-deleted-category-display",
    ]

    @Test(arguments: replayedCaseIDs)
    func replaysCategoryCase(caseID: String) async throws {
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "rows")
        let entry = try cases.entry(caseID)
        let actual = try await CategoryOracleReplay.replay(entry: entry, world: try Self.world())
        let expected = try CategoryOracleReplay.expected(entry)
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
            case "OP-103":
                withKnownIssue("OP-103: creating a category or group also writes tombstone 0") {
                    #expect(known.isEmpty, report)
                }
            case "OP-104":
                withKnownIssue("OP-104: income groups are not kept last in the category outline") {
                    #expect(known.isEmpty, report)
                }
            case "OP-105":
                withKnownIssue("OP-105: income categories can't be created or deleted in an envelope budget") {
                    #expect(known.isEmpty, report)
                }
            case "OP-106":
                withKnownIssue("OP-106: group names are trimmed") {
                    #expect(known.isEmpty, report)
                }
            case "OP-107":
                withKnownIssue("OP-107: category writes skip cells whose value does not change") {
                    #expect(known.isEmpty, report)
                }
            case "OP-108":
                withKnownIssue("OP-108: reordering renumbers every row in the group") {
                    #expect(known.isEmpty, report)
                }
            case "OP-109":
                withKnownIssue("OP-109: a deleted category still shows on its transactions") {
                    #expect(known.isEmpty, report)
                }
            default:
                Issue.record("divergence \(divergence.op) has no known-issue wrapper")
            }
        }
    }

    private static let writes = "^writes"
    private static let sortOrders = #"^rows\.(categories|category_groups)\[\d+\]\.sort_order$"#

    /// Registered divergences by fixture case. Anything outside a divergence's patterns stays a strict
    /// failure, so a new difference in a marked case still fails.
    private static let divergences: [String: [OracleKnownDivergence]] = [
        "cat-create-plain": [OracleKnownDivergence(op: "OP-103", patterns: [writes])],
        "cat-create-trimmed": [OracleKnownDivergence(op: "OP-103", patterns: [writes])],
        "cat-create-other-group": [OracleKnownDivergence(op: "OP-103", patterns: [writes])],
        "cat-create-empty-group": [OracleKnownDivergence(op: "OP-103", patterns: [writes])],
        "grp-create-plain": [
            OracleKnownDivergence(op: "OP-103", patterns: [writes]),
            OracleKnownDivergence(op: "OP-104", patterns: ["^order"]),
        ],
        "grp-create-trimmed": [
            OracleKnownDivergence(op: "OP-104", patterns: ["^order"]),
            OracleKnownDivergence(op: "OP-106", patterns: [writes, #"^rows\.category_groups"#]),
        ],
        "cat-create-income": [OracleKnownDivergence(op: "OP-105", patterns: [])],
        "cat-delete-income-transfer": [OracleKnownDivergence(op: "OP-105", patterns: [])],
        "cat-rename-plain": [OracleKnownDivergence(op: "OP-107", patterns: [writes])],
        "cat-rename-trimmed": [OracleKnownDivergence(op: "OP-107", patterns: [writes])],
        "cat-rename-case-only": [OracleKnownDivergence(op: "OP-107", patterns: [writes])],
        "cat-rename-unchanged": [OracleKnownDivergence(op: "OP-107", patterns: [writes])],
        "cat-hide": [OracleKnownDivergence(op: "OP-107", patterns: [writes])],
        "cat-unhide": [OracleKnownDivergence(op: "OP-107", patterns: [writes])],
        "grp-rename-plain": [OracleKnownDivergence(op: "OP-107", patterns: [writes])],
        "grp-hide": [OracleKnownDivergence(op: "OP-107", patterns: [writes])],
        "grp-unhide": [OracleKnownDivergence(op: "OP-107", patterns: [writes])],
        "cat-delete-budget-transfer": [OracleKnownDivergence(op: "OP-107", patterns: [writes])],
        "cat-move-within": [OracleKnownDivergence(op: "OP-108", patterns: [writes, sortOrders])],
        "cat-move-to-end": [OracleKnownDivergence(op: "OP-108", patterns: [writes, sortOrders])],
        "cat-move-other-group": [OracleKnownDivergence(op: "OP-108", patterns: [writes, sortOrders])],
        "cat-move-into-empty": [OracleKnownDivergence(op: "OP-108", patterns: [writes, sortOrders])],
        "grp-move-first": [OracleKnownDivergence(op: "OP-108", patterns: [writes, sortOrders])],
        "grp-move-end": [OracleKnownDivergence(op: "OP-108", patterns: [writes, sortOrders])],
        "read-deleted-category-display": [
            OracleKnownDivergence(op: "OP-109", patterns: [#"^transactions\[(0|2)\]\.category$"#]),
        ],
    ]

    @Test func partitionsEveryCategoryFixtureCase() throws {
        let manifest = try OracleManifest(
            domain: Self.domain,
            manifestName: "categories-manifest.json",
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
