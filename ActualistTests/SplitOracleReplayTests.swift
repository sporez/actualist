import Foundation
import Testing
@testable import Actualist

/// Replays each Splits oracle fixture through the production split family or rule-split executor.
/// Each fixture file has one replay test, parameterized over its replayed case ids.
struct SplitOracleReplayTests {
    private static let familyFile = "family-transformations.json"
    private static let ruleFile = "split-rule-cases.json"
    private static let mutationFile = "mutation-cases.json"

    private static let familyCaseIDs = [
        "make-child-inheritance-and-null-overrides",
        "recalculate-exact-mismatch-and-mixed-sign",
        "low-level-split-conversion-nulls-parent-payee-and-starts-with-error",
        "split-conversion-zero-sort-order",
        "parent-payee-update-preserves-child-override",
        "child-delete-recalculates-parent-error",
        "final-child-delete-collapses-parent",
    ]

    private static let ruleCaseIDs = [
        "index-zero-whole-transaction-and-one-based-children",
        "negative-half-percent-rounding",
        "positive-half-percent-rounding",
        "multiple-negative-remainders-adjust-highest-index",
        "fixed-before-percent-before-remainder",
        "formula-and-remainder",
        "effective-child-input-is-not-split",
    ]

    private static let mutationCaseIDs = [
        "add-child-appends-zero-remainder",
        "child-amount-update-recalculates-error",
        "child-amount-changed-to-zero",
        "parent-date-account-cleared-propagate",
        "parent-payee-update-preserves-child-override",
        "child-delete-recalculates-parent-error",
        "final-child-delete-collapses-parent",
    ]

    /// Mismatch paths that a registered divergence accounts for, by fixture case. Any other path fails.
    private static let knownPaths: [String: Set<String>] = [
        "split-conversion-zero-sort-order": ["family.children[0].sortOrder", "rows[1].sortOrder"],
        "parent-payee-update-preserves-child-override": ["diff.updated"],
        "final-child-delete-collapses-parent": ["diff.updated[0].is_parent"],
        "child-amount-changed-to-zero": ["diff.updated[0].amount"],
    ]

    @Test(arguments: familyCaseIDs)
    func replaysFamilyTransformation(caseID: String) throws {
        let divergence = try Self.divergenceSplit(fileName: Self.familyFile, caseID: caseID)
        #expect(divergence.strict.isEmpty, Comment(rawValue: OracleComparison.report(caseID, divergence.strict)))
        switch caseID {
        case "split-conversion-zero-sort-order":
            withKnownIssue("OP-15: a zero sort order is stored as 0 where the pinned Actual stores -1") {
                #expect(divergence.known.isEmpty, Comment(rawValue: OracleComparison.report(caseID, divergence.known)))
            }
        case "parent-payee-update-preserves-child-override", "final-child-delete-collapses-parent":
            withKnownIssue("OP-14: diffs drop cells changed to null, 0, or false") {
                #expect(divergence.known.isEmpty, Comment(rawValue: OracleComparison.report(caseID, divergence.known)))
            }
        default:
            break
        }
    }

    @Test(arguments: ruleCaseIDs)
    func replaysSplitRule(caseID: String) throws {
        try assertReplay(fileName: Self.ruleFile, caseID: caseID)
    }

    @Test(arguments: mutationCaseIDs)
    func replaysSplitMutation(caseID: String) throws {
        let divergence = try Self.divergenceSplit(fileName: Self.mutationFile, caseID: caseID)
        #expect(divergence.strict.isEmpty, Comment(rawValue: OracleComparison.report(caseID, divergence.strict)))
        switch caseID {
        case "child-amount-changed-to-zero", "parent-payee-update-preserves-child-override", "final-child-delete-collapses-parent":
            withKnownIssue("OP-14: diffs drop cells changed to null, 0, or false") {
                #expect(divergence.known.isEmpty, Comment(rawValue: OracleComparison.report(caseID, divergence.known)))
            }
        default:
            break
        }
    }

    @Test func partitionsEverySplitsFixtureCase() throws {
        let files = [
            (Self.familyFile, Self.familyCaseIDs),
            (Self.ruleFile, Self.ruleCaseIDs),
            (Self.mutationFile, Self.mutationCaseIDs),
        ]
        for (fileName, replayed) in files {
            let manifest = try OracleManifest(
                domain: "Splits",
                manifestName: "manifest.json",
                fileName: fileName
            )
            let cases = try OracleFixtureCases(domain: "Splits", fileName: fileName, outputKey: "expected")
            let problems = manifest.partitionProblems(fixtureIDs: cases.ids, replayed: replayed)
            #expect(problems.isEmpty, Comment(rawValue: "\(fileName): \(problems.joined(separator: "; "))"))
        }
    }

    private static func divergenceSplit(fileName: String, caseID: String) throws -> KnownDivergenceSplit {
        let cases = try OracleFixtureCases(domain: "Splits", fileName: fileName, outputKey: "expected")
        let actual = try SplitOracleReplay.replay(try cases.input(caseID))
        var comparison = OracleComparison()
        comparison.compare(
            expected: SplitOracleReplay.normalized(try cases.expected(caseID)),
            actual: SplitOracleReplay.normalized(actual)
        )
        return KnownDivergenceSplit(comparison.mismatches, knownPaths: knownPaths[caseID] ?? [])
    }

    private func assertReplay(fileName: String, caseID: String) throws {
        let cases = try OracleFixtureCases(domain: "Splits", fileName: fileName, outputKey: "expected")
        let actual = try SplitOracleReplay.replay(try cases.input(caseID))
        var comparison = OracleComparison()
        comparison.compare(
            expected: SplitOracleReplay.normalized(try cases.expected(caseID)),
            actual: SplitOracleReplay.normalized(actual)
        )
        #expect(
            comparison.mismatches.isEmpty,
            Comment(rawValue: OracleComparison.report(caseID, comparison.mismatches))
        )
    }
}
