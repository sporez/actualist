import Foundation
import Testing
@testable import Actualist

/// Replays the Transaction Command oracle contract through the production duplicate and merge
/// commands and ActionLog undo. One replay test covers every case id; the partition test accounts
/// for the manifest. The compared and excluded fields are documented in
/// `TransactionCommandOracleReplaySupport.swift` and `scripts/transaction-command-parity/README.md`.
@MainActor
struct TransactionCommandOracleReplayTests {
    private static let domain = "TransactionCommand"
    private static let fileName = "transaction-command-contract.json"

    /// Read by the `@Test(arguments:)` macro outside the suite's main-actor isolation.
    nonisolated private static let replayedCaseIDs = [
        "D1-simple-root",
        "D1-split-root-two-children",
        "D1-split-child-alone",
        "D1-parent-and-child",
        "D1-transfer-root",
        "D2-import-metadata-root",
        "D2-split-metadata-parent-only",
        "D2-sort-order-clone",
        "D2-transfer-pair-clone",
        "D2-split-error-clone",
        "D2-duplicate-does-not-request-learning",
        "M1-imported-over-manual-forward",
        "M1-imported-over-manual-reverse",
        "M1-imported-payee-over-manual",
        "M1-earlier-date-forward",
        "M1-earlier-date-reverse",
        "M1-equal-import-equal-date-forward",
        "M1-equal-import-equal-date-reverse",
        "M2-neither-split",
        "M2-keep-simple-drop-split",
        "M2-keep-split-drop-simple",
        "M2-both-splits-two-children",
        "M2-split-zero-children",
        "M2-split-one-child",
        "M2-selected-child-vs-simple",
        "M2-selected-children-same-parent",
        "M2-conflicting-split-families",
        "M3-neither-transfer",
        "M3-one-transfer-on-budget",
        "M3-one-transfer-off-budget",
        "M3-two-transfers-same-destination",
        "M3-two-transfers-different-destination",
        "M3-paired-reconciled",
        "M3-partial-transfer-pair",
        "M3-malformed-transfer-pair",
        "M4-atomic-forward-graph",
        "M4-atomic-reject-invalid-second-pair",
        "M4-undo-conflict-after-merge",
        "M4-undo-restores-both-graphs",
    ]

    /// How a registered divergence shows up in a case. Each kind states what must hold before the
    /// mismatches count as known; anything outside that stays a strict failure.
    private enum Kind {
        /// Actualist refuses where Actual merges or clones. The refusal writes nothing, so every
        /// comparison against Actual's changed rows is a consequence of it.
        case refusedWhereActualAllows
        /// Both refuse, but Actual's non-atomic handler clears transfer links before refusing.
        case actualWritesBeforeRefusing
        /// Actualist blocks the undo after a later edit; Actual's undo overwrites it.
        case undoBlockedAfterLaterEdit
    }

    private static let divergences: [String: (op: String, kind: Kind)] = [
        "D2-split-error-clone": ("OP-70", .refusedWhereActualAllows),
        "M2-selected-child-vs-simple": ("OP-71", .refusedWhereActualAllows),
        "M2-selected-children-same-parent": ("OP-71", .refusedWhereActualAllows),
        "M2-split-zero-children": ("OP-72", .refusedWhereActualAllows),
        "M2-conflicting-split-families": ("OP-72", .refusedWhereActualAllows),
        "M3-partial-transfer-pair": ("OP-73", .refusedWhereActualAllows),
        "M3-malformed-transfer-pair": ("OP-73", .refusedWhereActualAllows),
        "M2-keep-split-drop-simple": ("OP-74", .refusedWhereActualAllows),
        "M4-atomic-reject-invalid-second-pair": ("OP-75", .actualWritesBeforeRefusing),
        "M4-undo-conflict-after-merge": ("OP-76", .undoBlockedAfterLaterEdit),
    ]

    @Test(arguments: replayedCaseIDs)
    func replaysTransactionCommandCase(caseID: String) async throws {
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "handler")
        let entry = try cases.entry(caseID)
        let actual = try await TransactionCommandOracleReplay.replay(
            entry: entry,
            referenceData: try Self.referenceData(),
            makeDirectory: Self.makeDirectory
        )
        let expected = try TransactionCommandOracleReplay.expected(entry)
        var comparison = OracleComparison()
        comparison.compare(expected: expected, actual: actual)
        let mismatches = comparison.mismatches
        guard let divergence = Self.divergences[caseID] else {
            #expect(mismatches.isEmpty, Comment(rawValue: OracleComparison.report(caseID, mismatches)))
            return
        }

        let known: [ReplayMismatch]
        switch divergence.kind {
        case .refusedWhereActualAllows:
            #expect(expected.field("outcome") == .string("ok"))
            #expect(actual.field("outcome") == .string("refused"))
            #expect(actual.field("rows") == (try TransactionCommandOracleReplay.seededRows(entry)))
            known = mismatches
        case .actualWritesBeforeRefusing:
            #expect(expected.field("outcome") == .string("refused"))
            #expect(actual.field("outcome") == .string("refused"))
            #expect(actual.field("rows") == (try TransactionCommandOracleReplay.seededRows(entry)))
            known = mismatches.filter { $0.path.range(of: #"^rows\[\d+\]\.transfer_id$"#, options: .regularExpression) != nil }
        case .undoBlockedAfterLaterEdit:
            #expect(expected.field("undo")?.field("outcome") == .string("ok"))
            #expect(actual.field("undo")?.field("outcome") == .string("blocked"))
            known = mismatches.filter { $0.path.hasPrefix("undo.") }
        }
        let strict = mismatches.filter { mismatch in !known.contains(mismatch) }
        #expect(strict.isEmpty, Comment(rawValue: OracleComparison.report(caseID, strict)))
        let report = Comment(rawValue: OracleComparison.report(caseID, known))
        switch divergence.op {
        case "OP-70":
            withKnownIssue("OP-70: duplicating a malformed split is refused, where Actual clones it") {
                #expect(known.isEmpty, report)
            }
        case "OP-71":
            withKnownIssue("OP-71: merging a selected split child is refused") {
                #expect(known.isEmpty, report)
            }
        case "OP-72":
            withKnownIssue("OP-72: merging a zero-child or malformed split family is refused") {
                #expect(known.isEmpty, report)
            }
        case "OP-73":
            withKnownIssue("OP-73: merging a broken or partial transfer pair is refused") {
                #expect(known.isEmpty, report)
            }
        case "OP-74":
            withKnownIssue("OP-74: a split keeper that would gain the simple row's payee or category is refused") {
                #expect(known.isEmpty, report)
            }
        case "OP-75":
            withKnownIssue("OP-75: a refused merge writes nothing, where Actual clears transfer links first") {
                #expect(known.isEmpty, report)
            }
        case "OP-76":
            withKnownIssue("OP-76: undo is blocked after a later edit to a merged row") {
                #expect(known.isEmpty, report)
            }
        default:
            Issue.record("divergence \(divergence.op) has no known-issue wrapper")
        }
    }

    @Test func partitionsEveryTransactionCommandFixtureCase() throws {
        let manifest = try OracleManifest(
            domain: Self.domain,
            manifestName: "transaction-command-manifest.json",
            fileName: Self.fileName
        )
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "handler")
        let problems = manifest.partitionProblems(fixtureIDs: cases.ids, replayed: Self.replayedCaseIDs)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "; ")))
    }

    /// The fixture's top-level `referenceData`: the accounts, categories, payees and schedules every
    /// case starts from.
    private static func referenceData() throws -> [String: Any] {
        let url = try ParityOraclePin.fixtureURL(domain).appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OracleReplayError.missingFixture(url.path)
        }
        let root = try OracleJSON.object(OracleJSONFileCache.jsonObject(at: url), fileName)
        return try OracleJSON.object(root["referenceData"], "referenceData")
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TransactionCommandOracleReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
