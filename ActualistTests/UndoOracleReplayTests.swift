import Foundation
import Testing
@testable import Actualist

/// Replays the Undo oracle contract through the production History undo and, from the Payees
/// contract, the one-step payee undo. Each parameterized test covers every case id of its fixture;
/// the partition test accounts for both manifests. The compared and excluded fields are documented
/// in `UndoOracleReplaySupport.swift` and `scripts/undo-parity/README.md`.
@MainActor
struct UndoOracleReplayTests {
    private static let domain = "Undo"
    private static let fileName = "undo-contract.json"
    private static let payeeDomain = "Payees"
    private static let payeeFileName = "payees-contract.json"

    /// Read by the `@Test(arguments:)` macro outside the suite's main-actor isolation.
    nonisolated private static let replayedCaseIDs = [
        "assign-groceries",
        "move-dining-to-groceries",
        "create-simple",
        "edit-amount-payee",
        "delete-simple",
        "delete-split",
        "delete-transfer",
        "categorize-uncat",
        "batch-delete",
        "batch-categorize",
    ]

    /// The Payees fixture cases whose recorded undo this suite replays.
    nonisolated private static let replayedPayeeCaseIDs = [
        "create-plain",
        "create-trimmed",
        "create-padded-duplicate",
        "create-account-name",
        "create-normalised-padded",
        "rename-plain",
        "rename-trimmed",
        "rename-unchanged",
        "rename-case-only",
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
        "learn-global-on",
    ]

    @Test(arguments: replayedCaseIDs)
    func replaysUndoCase(caseID: String) async throws {
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "rowsAfterUndo")
        let entry = try cases.entry(caseID)
        let actual = try await UndoOracleReplay.replay(entry: entry, world: try Self.world(Self.domain, Self.fileName))
        let expected = try UndoOracleReplay.expected(entry)
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
            case "OP-122":
                withKnownIssue("OP-122: undoing a move clears no Reassigned note") {
                    #expect(known.isEmpty, report)
                }
            default:
                Issue.record("divergence \(divergence.op) has no known-issue wrapper")
            }
        }
    }

    @Test(arguments: replayedPayeeCaseIDs)
    func replaysPayeeUndoCase(caseID: String) async throws {
        let cases = try OracleFixtureCases(domain: Self.payeeDomain, fileName: Self.payeeFileName, outputKey: "rows")
        let entry = try cases.entry(caseID)
        let actual = try await UndoOracleReplay.replayPayeeUndo(
            entry: entry,
            world: try Self.world(Self.payeeDomain, Self.payeeFileName)
        )
        let expected = try UndoOracleReplay.expectedPayeeUndo(entry)
        var comparison = OracleComparison()
        comparison.compare(expected: expected, actual: actual)
        let values = "\nexpected \(expected.canonical)\nactual \(actual.canonical)"
        let divergences = Self.payeeDivergences[caseID] ?? []
        let strict = comparison.mismatches.filter { mismatch in
            !divergences.contains { $0.covers(mismatch.path) }
        }
        #expect(strict.isEmpty, Comment(rawValue: OracleComparison.report(caseID, strict) + values))
        for divergence in divergences {
            let known = comparison.mismatches.filter { divergence.covers($0.path) }
            let report = Comment(rawValue: OracleComparison.report(caseID, known) + values)
            switch divergence.op {
            case "OP-98":
                withKnownIssue("OP-98: payee writes skip cells whose value does not change") {
                    #expect(known.isEmpty, report)
                }
            default:
                Issue.record("divergence \(divergence.op) has no known-issue wrapper")
            }
        }
    }

    /// A path prefix `p` as a pattern: `p` itself, or `p` followed by `.` or `[`. Anything outside a registered
    /// divergence's paths stays a strict failure.
    private static func prefix(_ path: String) -> String {
        "^\(path)($|[.\\[].*)"
    }

    private static let divergences: [String: [OracleKnownDivergence]] = [
        "move-dining-to-groceries": [OracleKnownDivergence(op: "OP-122", patterns: [prefix("undoWrites")])],
    ]

    private static let payeeDivergences: [String: [OracleKnownDivergence]] = [
        "rename-unchanged": [OracleKnownDivergence(op: "OP-98", patterns: ["^(writes|outcome)$"])],
        "favorite-selection-mixed": [OracleKnownDivergence(op: "OP-98", patterns: [prefix("writes")])],
        "learn-selection-mixed": [OracleKnownDivergence(op: "OP-98", patterns: [prefix("writes")])],
    ]

    @Test func partitionsEveryUndoFixtureCase() throws {
        let manifest = try OracleManifest(domain: Self.domain, manifestName: "undo-manifest.json", fileName: Self.fileName)
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "rowsAfterUndo")
        let problems = manifest.partitionProblems(fixtureIDs: cases.ids, replayed: Self.replayedCaseIDs)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "; ")))
    }

    /// The undo manifest's `payeeUndo` lists the Payees cases it replays and the ones it does not, with
    /// reasons; together they must cover the Payees manifest's cases and match this suite's list.
    @Test func partitionsEveryPayeeFixtureCase() throws {
        let payeeManifest = try OracleManifest(
            domain: Self.payeeDomain,
            manifestName: "payees-manifest.json",
            fileName: Self.payeeFileName
        )
        let payeeCases = try OracleFixtureCases(domain: Self.payeeDomain, fileName: Self.payeeFileName, outputKey: "rows")
        let manifestURL = try ParityOraclePin.fixtureURL(Self.domain).appending(path: "undo-manifest.json")
        let root = try OracleJSON.object(OracleJSONFileCache.jsonObject(at: manifestURL), "undo-manifest.json")
        let listed = try OracleJSON.object(root["payeeUndo"], "payeeUndo")
        let manifestReplayed = listed["replayed"] as? [String] ?? []
        let omitted = try OracleJSON.objects(listed["oracleOnly"], "payeeUndo.oracleOnly")
        let omittedReasons = try Dictionary(uniqueKeysWithValues: omitted.map {
            (try OracleJSON.string($0, "id"), try OracleJSON.string($0, "reason"))
        })

        var problems = payeeManifest.partitionProblems(fixtureIDs: payeeCases.ids, replayed: manifestReplayed + Array(omittedReasons.keys))
        if manifestReplayed != Self.replayedPayeeCaseIDs {
            problems.append("the manifest's replayed payee ids differ from this suite's list")
        }
        for (id, reason) in omittedReasons where reason.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("omitted payee case \(id) has no reason")
        }
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "; ")))
    }

    /// The fixture's top-level `world`: the rows every case starts from.
    private static func world(_ domain: String, _ fileName: String) throws -> [String: Any] {
        let url = try ParityOraclePin.fixtureURL(domain).appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OracleReplayError.missingFixture(url.path)
        }
        let root = try OracleJSON.object(OracleJSONFileCache.jsonObject(at: url), fileName)
        return try OracleJSON.object(root["world"], "world")
    }
}
