import Foundation
import Testing
@testable import Actualist

/// Replays the Rules oracle contract through the production `previewRules` path. Every run of every
/// replayed case compares the whole normalized transaction; see `scripts/rule-parity/README.md`
/// ("Swift replay") for the compared and excluded fields. The partition test accounts for every case.
@MainActor
struct RuleOracleReplayTests {
    private static let fileName = "rules-contract.json"
    private static let manifestName = "rules-manifest.json"

    /// Read by the `@Test(arguments:)` macro outside the suite's main-actor isolation.
    nonisolated private static let replayedCaseIDs = [
        "control-no-rules",
        "control-non-matching",
        "payee-is-resolved-payee-id",
        "imported-payee-raw-text",
        "imported-payee-empty-null-absent",
        "imported-payee-firstchar-index",
        "notes-set-null-and-empty",
        "notes-prepend-append-empty-and-existing",
        "transfer-payee-set-by-rule",
        "payee-set-then-later-payee-rules",
        "payee-isnot-single-condition",
        "index-excludes-or-rule-with-two-indexed-conditions",
        "payee-absent-vs-null-id-conditions",
        "offbudget-account-sets-category",
        "regex-special-characters-case-insensitive",
        "regex-uppercase-class-is-lowercased",
        "amount-isapprox-boundaries",
        "amount-isbetween-reversed-and-inclusive",
        "amount-zero-with-inflow-outflow-options",
        "date-recurring-schedule-style-value",
        "date-month-and-year-values",
        "schedule-rule-links-by-conditions",
        "schedule-attached-runs-its-rule-regardless-of-conditions",
        "schedule-rule-with-plain-conditions-active-and-completed",
        "link-schedule-action-then-later-rules",
        "same-field-last-rule-wins-within-stage",
        "same-field-stage-order",
        "same-score-id-tie-break",
        "rank-scores-by-operator",
        "notes-unicode-and-case",
        "hastags-edge-cases",
        "delete-transaction-then-later-rules",
        "category-group-condition-after-category-change",
        "transfer-and-parent-conditions-in-run-rules",
        "invalid-and-empty-rules-are-ignored",
        "set-account-and-date-and-amount",
        "split-fixed-and-remainder-interaction",
        "split-amount-formula-literal-and-balance-of",
        "gen-cond-payee-is-1",
        "gen-cond-payee-is-2",
        "gen-cond-payee-isnot-1",
        "gen-cond-payee-isnot-2",
        "gen-cond-payee-oneof-1",
        "gen-cond-payee-oneof-2",
        "gen-cond-payee-notoneof-1",
        "gen-cond-payee-notoneof-2",
        "gen-cond-payee-contains-id-1",
        "gen-cond-payee-contains-id-2",
        "gen-cond-payee-matches-id-1",
        "gen-cond-payee-matches-id-2",
        "gen-cond-payee-name-is-1",
        "gen-cond-payee-name-is-2",
        "gen-cond-payee-name-contains-1",
        "gen-cond-payee-name-contains-2",
        "gen-cond-imported-is-1",
        "gen-cond-imported-is-2",
        "gen-cond-imported-isnot-1",
        "gen-cond-imported-isnot-2",
        "gen-cond-imported-oneof-1",
        "gen-cond-imported-oneof-2",
        "gen-cond-imported-notoneof-1",
        "gen-cond-imported-notoneof-2",
        "gen-cond-imported-contains-1",
        "gen-cond-imported-contains-2",
        "gen-cond-imported-doesnotcontain-1",
        "gen-cond-imported-doesnotcontain-2",
        "gen-cond-imported-matches-1",
        "gen-cond-imported-matches-2",
        "gen-cond-imported-matches-invalid-1",
        "gen-cond-imported-matches-invalid-2",
        "gen-cond-notes-is-1",
        "gen-cond-notes-is-2",
        "gen-cond-notes-isnot-1",
        "gen-cond-notes-isnot-2",
        "gen-cond-notes-contains-1",
        "gen-cond-notes-contains-2",
        "gen-cond-notes-doesnotcontain-1",
        "gen-cond-notes-doesnotcontain-2",
        "gen-cond-notes-matches-1",
        "gen-cond-notes-matches-2",
        "gen-cond-notes-hastags-1",
        "gen-cond-notes-hastags-2",
        "gen-cond-notes-hasanytag-1",
        "gen-cond-notes-hasanytag-2",
        "gen-cond-amount-is-1",
        "gen-cond-amount-is-2",
        "gen-cond-amount-isapprox-1",
        "gen-cond-amount-isapprox-2",
        "gen-cond-amount-isbetween-1",
        "gen-cond-amount-isbetween-2",
        "gen-cond-amount-isbetween-reversed-1",
        "gen-cond-amount-isbetween-reversed-2",
        "gen-cond-amount-gt-1",
        "gen-cond-amount-gt-2",
        "gen-cond-amount-gte-1",
        "gen-cond-amount-gte-2",
        "gen-cond-amount-lt-1",
        "gen-cond-amount-lt-2",
        "gen-cond-amount-lte-1",
        "gen-cond-amount-lte-2",
        "gen-cond-amount-inflow-gt-1",
        "gen-cond-amount-inflow-gt-2",
        "gen-cond-amount-outflow-gt-1",
        "gen-cond-amount-outflow-gt-2",
        "gen-cond-amount-outflow-isbetween-1",
        "gen-cond-amount-outflow-isbetween-2",
        "gen-cond-amount-outflow-isapprox-1",
        "gen-cond-amount-outflow-isapprox-2",
        "gen-cond-amount-inflow-is-zero-1",
        "gen-cond-amount-inflow-is-zero-2",
        "gen-cond-date-is-1",
        "gen-cond-date-is-2",
        "gen-cond-date-is-month-1",
        "gen-cond-date-is-month-2",
        "gen-cond-date-is-year-1",
        "gen-cond-date-is-year-2",
        "gen-cond-date-isapprox-1",
        "gen-cond-date-isapprox-2",
        "gen-cond-date-gt-1",
        "gen-cond-date-gt-2",
        "gen-cond-date-gte-1",
        "gen-cond-date-gte-2",
        "gen-cond-date-lt-1",
        "gen-cond-date-lt-2",
        "gen-cond-date-lte-1",
        "gen-cond-date-lte-2",
        "gen-cond-date-is-recur-1",
        "gen-cond-date-is-recur-2",
        "gen-cond-date-isapprox-recur-1",
        "gen-cond-date-isapprox-recur-2",
        "gen-cond-date-is-recur-biweekly-1",
        "gen-cond-date-is-recur-biweekly-2",
        "gen-cond-date-is-recur-skip-weekend-1",
        "gen-cond-date-is-recur-skip-weekend-2",
        "gen-cond-date-is-recur-ended-1",
        "gen-cond-date-is-recur-ended-2",
        "gen-cond-account-is-1",
        "gen-cond-account-is-2",
        "gen-cond-account-isnot-1",
        "gen-cond-account-isnot-2",
        "gen-cond-account-oneof-1",
        "gen-cond-account-oneof-2",
        "gen-cond-account-notoneof-1",
        "gen-cond-account-notoneof-2",
        "gen-cond-account-onbudget-1",
        "gen-cond-account-onbudget-2",
        "gen-cond-account-offbudget-1",
        "gen-cond-account-offbudget-2",
        "gen-cond-category-is-1",
        "gen-cond-category-is-2",
        "gen-cond-category-is-null-1",
        "gen-cond-category-is-null-2",
        "gen-cond-category-isnot-1",
        "gen-cond-category-isnot-2",
        "gen-cond-category-oneof-1",
        "gen-cond-category-oneof-2",
        "gen-cond-category-group-is-1",
        "gen-cond-category-group-is-2",
        "gen-cond-cleared-is-true-1",
        "gen-cond-cleared-is-true-2",
        "gen-cond-cleared-is-false-1",
        "gen-cond-cleared-is-false-2",
        "gen-cond-reconciled-is-true-1",
        "gen-cond-reconciled-is-true-2",
        "gen-action-set-category",
        "gen-action-clear-category",
        "gen-action-set-payee",
        "gen-action-set-payee-transfer",
        "gen-action-set-notes",
        "gen-action-clear-notes-null",
        "gen-action-clear-notes-empty",
        "gen-action-set-cleared",
        "gen-action-set-account",
        "gen-action-set-account-offbudget",
        "gen-action-set-date",
        "gen-action-set-amount",
        "gen-action-prepend-notes",
        "gen-action-append-notes",
        "gen-action-link-schedule",
        "gen-action-delete-transaction",
        "gen-action-multi-field",
        "gen-rank-01",
        "gen-rank-02",
        "gen-rank-03",
        "gen-rank-04",
        "gen-rank-05",
        "gen-rank-06",
        "gen-rank-07",
        "gen-rank-08",
        "gen-rank-09",
        "gen-rank-10",
        "gen-rank-11",
        "gen-rank-12",
        "gen-rank-13",
        "gen-rank-14",
        "gen-rank-15",
        "gen-rank-16",
        "gen-rank-17",
        "gen-rank-18",
        "gen-rank-19",
        "gen-rank-20",
        "gen-rank-21",
        "gen-rank-22",
        "gen-rank-23",
        "gen-rank-24",
        "gen-rank-25",
        "gen-rank-26",
        "gen-rank-27",
        "gen-rank-28",
        "gen-rank-29",
        "gen-rank-30",
        "gen-rank-31",
        "gen-rank-32",
        "gen-rank-33",
        "gen-rank-34",
        "gen-rank-35",
        "gen-rank-36",
        "gen-rank-37",
        "gen-rank-38",
        "gen-rank-39",
        "gen-rank-40",
        "gen-join-01-and",
        "gen-join-02-or",
        "gen-join-03-and",
        "gen-join-04-or",
        "gen-join-05-and",
        "gen-join-06-or",
        "gen-join-07-and",
        "gen-join-08-or",
        "gen-join-09-and",
        "gen-join-10-or",
        "gen-join-11-and",
        "gen-join-12-or",
        "gen-join-13-and",
        "gen-join-14-or",
        "gen-join-15-and",
        "gen-join-16-or",
        "gen-join-17-and",
        "gen-join-18-or",
        "gen-join-19-and",
        "gen-join-20-or",
        "gen-join-21-and",
        "gen-join-22-or",
        "gen-join-23-and",
        "gen-join-24-or",
    ]

    @Test
    func manifestPartitionsEveryContractCase() throws {
        let cases = try OracleFixtureCases(domain: "Rules", fileName: Self.fileName, outputKey: "runs")
        let manifest = try OracleManifest(domain: "Rules", manifestName: Self.manifestName, fileName: Self.fileName)
        let problems = manifest.partitionProblems(fixtureIDs: cases.ids, replayed: Self.replayedCaseIDs)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test
    func fixtureMatchesThePinnedOracle() throws {
        let pin = try ParityOraclePin.load()
        let url = try ParityOraclePin.fixtureURL("Rules").appending(path: Self.manifestName)
        let manifest = try OracleJSON.object(JSONSerialization.jsonObject(with: Data(contentsOf: url)), Self.manifestName)
        let actual = try OracleJSON.object(manifest["actual"], "actual")
        #expect(actual["tag"] as? String == pin.tag)
        #expect(actual["commit"] as? String == pin.commit)
        #expect(manifest["timeZone"] as? String == RuleOracleReplay.timeZone.identifier)
    }

    @Test(arguments: replayedCaseIDs)
    func replaysRuleCase(caseID: String) async throws {
        let cases = try OracleFixtureCases(domain: "Rules", fileName: Self.fileName, outputKey: "runs")
        let result = try await RuleOracleReplay.replay(try cases.entry(caseID))
        #expect(!result.runs.isEmpty, "\(caseID) replayed no runs")

        // Mismatches a registered divergence accounts for are split off by exact run.field path; every other
        // mismatch stays strict, so a case with a divergence still compares all its other fields.
        var remaining = result.runs.flatMap(\.mismatches)
        func take(_ table: [String: Set<String>]) -> [ReplayMismatch] {
            guard let paths = table[caseID] else { return [] }
            let split = KnownDivergenceSplit(remaining, knownPaths: paths)
            remaining = split.strict
            return split.known
        }
        let op36 = take(Self.op36Paths)
        let op37 = take(Self.op37Paths)
        let op38 = take(Self.op38Paths)
        let op39 = take(Self.op39Paths)
        let op40 = take(Self.op40Paths)
        let op41 = take(Self.op41Paths)
        let op42 = take(Self.op42Paths)
        let op43 = take(Self.op43Paths)
        let op44 = take(Self.op44Paths)
        let op45 = take(Self.op45Paths)

        #expect(remaining.isEmpty, Comment(rawValue: OracleComparison.report(caseID, remaining)))
        if !op36.isEmpty {
            withKnownIssue("OP-36: a set-account action (stored as acct) is not recognised, so the whole rule is skipped") {
                #expect(op36.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op36)))
            }
        }
        if !op37.isEmpty {
            withKnownIssue("OP-37: a delete-transaction action without a value key fails to decode, so the whole rule is skipped") {
                #expect(op37.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op37)))
            }
        }
        if !op38.isEmpty {
            withKnownIssue("OP-38: a set-notes action with an empty string stores nil, where the oracle keeps an empty string") {
                #expect(op38.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op38)))
            }
        }
        if !op39.isEmpty {
            withKnownIssue("OP-39: a date condition with a recurrence value never matches") {
                #expect(op39.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op39)))
            }
        }
        if !op40.isEmpty {
            withKnownIssue("OP-40: contains and matches on payee compare the payee name, where the oracle compares the payee id") {
                #expect(op40.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op40)))
            }
        }
        if !op41.isEmpty {
            withKnownIssue("OP-41: every ranked rule is a candidate, where the oracle skips rules its payee and imported-payee indexes miss") {
                #expect(op41.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op41)))
            }
        }
        if !op42.isEmpty {
            withKnownIssue("OP-42: payee_name is refreshed after a rule sets the payee, where the oracle reads it once before any rule runs") {
                #expect(op42.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op42)))
            }
        }
        if !op43.isEmpty {
            withKnownIssue("OP-43: a rule-created split keeps the parent payee, where the oracle clears it") {
                #expect(op43.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op43)))
            }
        }
        if !op44.isEmpty {
            withKnownIssue("OP-44: transfer and parent conditions are evaluated, where the oracle's runRules never matches them") {
                #expect(op44.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op44)))
            }
        }
        if !op45.isEmpty {
            withKnownIssue("OP-45: a rule linked to a completed schedule is skipped, where the oracle still runs it") {
                #expect(op45.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op45)))
            }
        }
    }

    // MARK: Known divergences (config/parity/known-divergences.json)

    private static let op36Paths: [String: Set<String>] = [
        "gen-action-set-account": ["base.account", "inflow.account", "offbudget-account.account"],
        "gen-action-set-account-offbudget": ["base.account", "inflow.account"],
        "set-account-and-date-and-amount": ["base.account", "base.amount", "base.cleared", "base.date", "base.notes"],
    ]

    private static let op37Paths: [String: Set<String>] = [
        "delete-transaction-then-later-rules": ["deleted.deleted"],
        "gen-action-delete-transaction": ["base.deleted", "inflow.deleted", "offbudget-account.deleted"],
    ]

    private static let op38Paths: [String: Set<String>] = [
        "gen-action-clear-notes-empty": ["base.notes", "inflow.notes", "offbudget-account.notes"],
        "notes-set-null-and-empty": ["cafe.notes"],
    ]

    private static let op39Paths: [String: Set<String>] = [
        "date-recurring-schedule-style-value": ["ended-series-last.cleared", "on-fifth.category", "saturday-third.category", "saturday-third.notes", "two-days-after.category"],
        "gen-cond-date-is-recur-1": ["hit-1.category", "hit-2.category"],
        "gen-cond-date-is-recur-2": ["hit-1.category", "hit-1.cleared", "hit-1.notes", "hit-2.category", "hit-2.cleared", "hit-2.notes"],
        "gen-cond-date-is-recur-biweekly-1": ["hit-1.category", "hit-1.cleared", "hit-1.notes"],
        "gen-cond-date-is-recur-biweekly-2": ["hit-1.amount"],
        "gen-cond-date-is-recur-ended-1": ["hit-1.schedule"],
        "gen-cond-date-is-recur-ended-2": ["hit-1.category"],
        "gen-cond-date-is-recur-skip-weekend-1": ["miss-1.schedule"],
        "gen-cond-date-is-recur-skip-weekend-2": ["miss-1.notes"],
        "gen-cond-date-isapprox-recur-2": ["hit-1.date", "hit-2.date"],
        "schedule-attached-runs-its-rule-regardless-of-conditions": ["attached-unknown.schedule"],
        "schedule-rule-links-by-conditions": ["done-schedule-match.schedule", "rent-late.schedule", "rent.schedule"],
    ]

    private static let op40Paths: [String: Set<String>] = [
        "gen-cond-payee-contains-id-1": ["hit-1.amount"],
        "gen-cond-payee-contains-id-2": ["hit-1.notes"],
        "gen-cond-payee-matches-id-1": ["hit-1.notes"],
        "gen-cond-payee-matches-id-2": ["hit-1.category", "hit-1.cleared", "hit-1.notes"],
    ]

    private static let op41Paths: [String: Set<String>] = [
        "index-excludes-or-rule-with-two-indexed-conditions": ["store-costco.category", "store-zebra.category"],
    ]

    private static let op42Paths: [String: Set<String>] = [
        "payee-set-then-later-payee-rules": ["base.notes"],
    ]

    private static let op43Paths: [String: Set<String>] = [
        "split-amount-formula-literal-and-balance-of": ["base.payee", "before-history.payee"],
        "split-fixed-and-remainder-interaction": ["base.payee"],
    ]

    private static let op44Paths: [String: Set<String>] = [
        "transfer-and-parent-conditions-in-run-rules": ["base.cleared", "base.notes"],
    ]

    private static let op45Paths: [String: Set<String>] = [
        "schedule-rule-with-plain-conditions-active-and-completed": ["completed.schedule"],
    ]
}
