import Foundation
import Testing
@testable import Actualist

/// Replays the Transaction Query oracle contract (Q1 conditions, Q2 saved filters, Q3 split families and
/// the split modes) through the production query and saved-filter paths. The compared and excluded
/// fields are documented in `TransactionQueryOracleReplaySupport.swift` and
/// `scripts/transaction-query-parity/README.md`. The partition test accounts for every fixture case.
@MainActor
struct TransactionQueryOracleReplayTests {
    private static let domain = "TransactionQuery"
    private static let fileName = "transaction-query-contract.json"
    private static let manifestName = "transaction-query-manifest.json"

    /// Read by the `@Test(arguments:)` macro outside the suite's main-actor isolation.
    nonisolated private static let queryCaseIDs = [
        "q1-date-is-day",
        "q1-date-isapprox-day",
        "q1-date-gt-exclusive-lower",
        "q1-date-gte-inclusive-lower",
        "q1-date-lt-exclusive-upper",
        "q1-date-lte-inclusive-upper",
        "q1-account-is",
        "q1-account-is-not",
        "q1-account-one-of",
        "q1-account-not-one-of",
        "q1-payee-is-mapped-id",
        "q1-payee-is-not-null",
        "q1-payee-one-of",
        "q1-payee-not-one-of",
        "q1-payee-is-null",
        "q1-category-is-mapped-id",
        "q1-category-is-not-null",
        "q1-category-one-of",
        "q1-category-not-one-of",
        "q1-category-is-null-uncategorized",
        "q3-date-family-grouping",
        "q3-account-family-grouping",
        "q3-payee-child-selects-family",
        "q3-category-child-selects-family",
        "q3-free-text-grouped-versus-physical",
    ]

    nonisolated private static let savedFilterCaseIDs = [
        "q2-exact-condition-equivalence",
        "q2-reordered-condition-equivalence",
        "q2-duplicate-condition-multiplicity",
        "q2-number-versus-string-value",
        "q2-options-key-order",
        "q2-single-condition-and-versus-or",
        "q2-multiple-condition-and-versus-or-control",
        "q2-duplicate-live-name-precedes-condition-check",
    ]

    nonisolated private static let splitModeCaseIDs = [
        "split-modes-two-child-family",
        "child-note-search",
        "dead-parent-excludes-orphan",
        "flag-disagreement-parent-id-without-is-child",
        "default-order",
    ]

    private static var replayedCaseIDs: [String] {
        queryCaseIDs + savedFilterCaseIDs + splitModeCaseIDs
    }

    @Test func fixtureMatchesThePinnedOracle() throws {
        let pin = try ParityOraclePin.load()
        let root = try Self.loadRoot()
        let oracle = try OracleJSON.object(root["oracle"], "oracle")
        #expect(oracle["tag"] as? String == pin.tag)
        #expect(oracle["commit"] as? String == pin.commit)
        let manifestURL = try ParityOraclePin.fixtureURL(Self.domain).appending(path: Self.manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw OracleReplayError.missingFixture(manifestURL.path)
        }
        let manifest = try OracleJSON.object(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)),
            Self.manifestName
        )
        let actual = try OracleJSON.object(manifest["actual"], "actual")
        #expect(actual["tag"] as? String == pin.tag)
        #expect(actual["commit"] as? String == pin.commit)
    }

    @Test(arguments: queryCaseIDs)
    func replaysQueryCase(caseID: String) async throws {
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "physical")
        let entry = try cases.entry(caseID)
        let world = try Self.world(named: OracleJSON.string(entry, "world"))
        let actual = try await TransactionQueryOracleReplay.replayQuery(
            entry, world: world, makeDirectory: Self.makeDirectory
        )
        Self.assertReplay(caseID, expected: try TransactionQueryOracleReplay.expectedQuery(entry), actual: actual)
    }

    @Test(arguments: savedFilterCaseIDs)
    func replaysSavedFilterCase(caseID: String) async throws {
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "filter")
        let entry = try cases.entry(caseID)
        let actual = try await TransactionQueryOracleReplay.replayFilterCase(entry, makeDirectory: Self.makeDirectory)
        Self.assertReplay(caseID, expected: try TransactionQueryOracleReplay.expectedFilterCase(entry), actual: actual)
    }

    @Test(arguments: splitModeCaseIDs)
    func replaysSplitModeCase(caseID: String) async throws {
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "results")
        let entry = try cases.entry(caseID)
        let world = try Self.world(named: OracleJSON.string(entry, "world"))
        let actual = try await TransactionQueryOracleReplay.replaySplitModes(
            entry, world: world, makeDirectory: Self.makeDirectory
        )
        Self.assertReplay(caseID, expected: try TransactionQueryOracleReplay.expectedSplitModes(entry), actual: actual)
    }

    @Test func partitionsEveryTransactionQueryFixtureCase() throws {
        let manifest = try OracleManifest(domain: Self.domain, manifestName: Self.manifestName, fileName: Self.fileName)
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "physical")
        let problems = manifest.partitionProblems(fixtureIDs: cases.ids, replayed: Self.replayedCaseIDs)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "; ")))
        for (id, reason) in manifest.oracleOnly {
            #expect(
                reason == "feature gap: operator not supported by Actualist filters (user decision 2026-10-11)",
                Comment(rawValue: "oracle-only case \(id) has an unexpected reason")
            )
        }
    }

    // MARK: - Comparison

    /// Field paths (index suffixes dropped) that a registered divergence accounts for. Every other
    /// mismatch of the case stays a strict failure.
    private static let divergences: [String: (op: String, paths: Set<String>)] = [
        "q3-free-text-grouped-versus-physical": ("OP-78", ["rootIDs", "displayedIDs", "contextIDs", "unmatchedIDs"]),
        "dead-parent-excludes-orphan": ("OP-79", ["results.all.ids"]),
    ]

    private static func assertReplay(_ caseID: String, expected: OracleValue, actual: OracleValue) {
        var comparison = OracleComparison()
        comparison.compare(expected: expected, actual: actual)
        let mismatches = comparison.mismatches
        guard let divergence = divergences[caseID] else {
            #expect(mismatches.isEmpty, Comment(rawValue: OracleComparison.report(caseID, mismatches)))
            return
        }

        let known = mismatches.filter { divergence.paths.contains($0.path.replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)) }
        let strict = mismatches.filter { mismatch in !known.contains(mismatch) }
        #expect(strict.isEmpty, Comment(rawValue: OracleComparison.report(caseID, strict)))
        let report = Comment(rawValue: OracleComparison.report(caseID, known))
        switch divergence.op {
        case "OP-78":
            #expect(actual.field("rootIDs") == .array([.string("family-target")]))
            withKnownIssue("OP-78: free-text search returns the matching child alone, where Actual groups it to the parent") {
                #expect(known.isEmpty, report)
            }
        case "OP-79":
            #expect(actual.field("results")?.field("all")?.field("ids") == .array([.string("simple")]))
            withKnownIssue("OP-79: the all-rows read hides children of a deleted or missing parent") {
                #expect(known.isEmpty, report)
            }
        default:
            Issue.record("divergence \(divergence.op) has no known-issue wrapper")
        }
    }

    // MARK: - Fixture access

    private static func loadRoot() throws -> [String: Any] {
        let url = try ParityOraclePin.fixtureURL(domain).appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OracleReplayError.missingFixture(url.path)
        }
        return try OracleJSON.object(JSONSerialization.jsonObject(with: Data(contentsOf: url)), fileName)
    }

    /// One of the fixture's top-level `worlds`: the rows a case starts from.
    private static func world(named name: String) throws -> [String: Any] {
        let worlds = try OracleJSON.object(loadRoot()["worlds"], "worlds")
        return try OracleJSON.object(worlds[name], "world \(name)")
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TransactionQueryOracleReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private extension OracleValue {
    func field(_ key: String) -> OracleValue? {
        guard case .object(let fields) = self else {
            return nil
        }
        return fields[key]
    }
}
