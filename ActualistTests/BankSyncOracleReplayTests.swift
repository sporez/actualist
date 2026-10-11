import Foundation
import Testing
@testable import Actualist

/// Replays the BankSync oracle contract through the production import reconcile (see
/// `BankSyncOracleReplay`). Every replayed case compares the plan classification, the rows, payees and
/// rules after the call, and, for CSV, the candidates production built. See
/// `scripts/bank-sync-parity/README.md` ("Swift replay") for the compared and excluded parts. The
/// partition test accounts for every case.
@MainActor
struct BankSyncOracleReplayTests {
    @Test
    func manifestPartitionsEveryContractCase() throws {
        let fixture = try BankSyncOracleFixture.load()
        let manifest = try OracleManifest(
            domain: "BankSync",
            manifestName: BankSyncOracleFixture.manifestName,
            fileName: BankSyncOracleFixture.fileName
        )
        let problems = manifest.partitionProblems(fixtureIDs: fixture.ids, replayed: BankSyncOracleCaseIDs.replayed)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test
    func fixtureMatchesThePinnedOracleAndEnvironment() throws {
        let pin = try ParityOraclePin.load()
        let fixture = try BankSyncOracleFixture.load()
        let url = try ParityOraclePin.fixtureURL("BankSync").appending(path: BankSyncOracleFixture.manifestName)
        let manifest = try OracleJSON.object(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)),
            BankSyncOracleFixture.manifestName
        )
        let actual = try OracleJSON.object(manifest["actual"], "actual")
        #expect(actual["tag"] as? String == pin.tag)
        #expect(actual["commit"] as? String == pin.commit)
        #expect(manifest["timeZone"] as? String == BankSyncOracleReplay.timeZone.identifier)
        #expect(manifest["today"] as? String == "2026-10-15")
        let oracle = try OracleJSON.object(fixture.root["oracle"], "oracle")
        #expect(oracle["tag"] as? String == pin.tag)
        #expect(oracle["commit"] as? String == pin.commit)
        let environment = try OracleJSON.object(fixture.root["environment"], "environment")
        #expect(environment["timeZone"] as? String == BankSyncOracleReplay.timeZone.identifier)
        #expect(environment["today"] as? String == "2026-10-15")
    }

    @Test(arguments: BankSyncOracleCaseIDs.replayed)
    func replaysBankSyncCase(caseID: String) async throws {
        let fixture = try BankSyncOracleFixture.load()
        let comparison = try await BankSyncOracleReplay.replay(try fixture.entry(caseID), fixture: fixture)

        // Mismatches a registered divergence accounts for are split off by exact path; every other
        // mismatch stays strict, so a case with a divergence still compares all its other fields.
        var remaining = comparison.mismatches
        func take(_ table: [String: Set<String>]) -> [ReplayMismatch] {
            guard let paths = table[caseID] else { return [] }
            let split = KnownDivergenceSplit(remaining, knownPaths: paths)
            remaining = split.strict
            return split.known
        }

        let op54 = take(Self.op54Paths)
        let op55 = take(Self.op55Paths)
        let op56 = take(Self.op56Paths)
        let op57 = take(Self.op57Paths)
        let op58 = take(Self.op58Paths)
        let op59 = take(Self.op59Paths)
        let op60 = take(Self.op60Paths)
        let op61 = take(Self.op61Paths)
        let op62 = take(Self.op62Paths)
        let op63 = take(Self.op63Paths)
        let op64 = take(Self.op64Paths)
        let op65 = take(Self.op65Paths)
        let op66 = take(Self.op66Paths)
        let op67 = take(Self.op67Paths)
        let op68 = take(Self.op68Paths)
        let op69 = take(Self.op69Paths)

        #expect(remaining.isEmpty, Comment(rawValue: OracleComparison.report(caseID, remaining)))
        if !op54.isEmpty {
            withKnownIssue("OP-54: a first sync is detected from every live row, where the oracle ignores rows dated after today") {
                #expect(op54.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op54)))
            }
        }
        if !op55.isEmpty {
            withKnownIssue("OP-55: Bank Sync matches a provider ID only inside the seven-day window, where the oracle matches it on any date") {
                #expect(op55.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op55)))
            }
        }
        if !op56.isEmpty {
            withKnownIssue("OP-56: a matched row keeps its date, where the oracle moves it when update-dates is on") {
                #expect(op56.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op56)))
            }
        }
        if !op57.isEmpty {
            withKnownIssue("OP-57: a matched payee-less row does not take a new payee, where the oracle creates it and sets it") {
                #expect(op57.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op57)))
            }
        }
        if !op58.isEmpty {
            withKnownIssue("OP-58: a matched off-budget row never takes a category, where the oracle fills it") {
                #expect(op58.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op58)))
            }
        }
        if !op59.isEmpty {
            withKnownIssue("OP-59: the opening balance is derived from planned inserts, where the oracle subtracts the raw download") {
                #expect(op59.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op59)))
            }
        }
        if !op60.isEmpty {
            withKnownIssue("OP-60: the opening balance takes the earliest download day, where the oracle takes the last row's date") {
                #expect(op60.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op60)))
            }
        }
        if !op61.isEmpty {
            withKnownIssue("OP-61: a deleted row's ID is skipped, where the oracle matches and rewrites the deleted row") {
                #expect(op61.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op61)))
            }
        }
        if !op62.isEmpty {
            withKnownIssue("OP-62: children of an ID-matched split parent are reserved, where the pinned oracle lets a download match one") {
                #expect(op62.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op62)))
            }
        }
        if !op63.isEmpty {
            withKnownIssue("OP-63: a transfer payee is not filled onto a matched plain row, where the oracle sets it and creates the leg") {
                #expect(op63.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op63)))
            }
        }
        if !op64.isEmpty {
            withKnownIssue("OP-64: a delete-transaction rule is skipped (same cause as OP-37), so its download is imported") {
                #expect(op64.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op64)))
            }
        }
        if !op65.isEmpty {
            withKnownIssue("OP-65: a blank payee text stores a null imported payee, where the oracle stores an empty string") {
                #expect(op65.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op65)))
            }
        }
        if !op66.isEmpty {
            withKnownIssue("OP-66: a padded provider payee name is created trimmed, where the oracle keeps the spaces") {
                #expect(op66.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op66)))
            }
        }
        if !op67.isEmpty {
            withKnownIssue("OP-67: an equal-distance tie picks the first stored row, where the oracle picks another") {
                #expect(op67.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op67)))
            }
        }
        if !op68.isEmpty {
            withKnownIssue("OP-68: a duplicated provider ID matches a different row than the oracle's") {
                #expect(op68.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op68)))
            }
        }
        if !op69.isEmpty {
            withKnownIssue("OP-69: file import ignores the reimport-deleted preference, where the oracle reads it") {
                #expect(op69.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op69)))
            }
        }
    }

    // MARK: Known divergences (config/parity/known-divergences.json)

    private static let op54Paths: [String: Set<String>] = [
        "named-first-sync-future-dated-rows-only": ["transactions.new-2", "payees.new-payee:Starting Balance"],
    ]

    private static let op55Paths: [String: Set<String>] = [
        "gen-fuzzy-083": ["result.addedCount", "result.updated", "transactions.ex-1.imported_payee", "transactions.new-1"],
        "gen-fuzzy-085": ["result.addedCount", "result.updated", "transactions.ex-1.imported_payee", "transactions.ex-1.notes", "transactions.new-1"],
        "named-id-match-outside-window-bank": ["result.addedCount", "result.updated", "transactions.ex-1.imported_payee", "transactions.ex-1.payee", "transactions.new-1"],
        "named-id-match-outside-window-simplefin": ["result.addedCount", "result.updated", "transactions.ex-1.imported_payee", "transactions.ex-1.payee", "transactions.new-1"],
        "named-split-parent-match-by-imported-id": ["result.addedCount", "result.updated", "transactions.new-1", "transactions.sp-1.cleared", "transactions.sp-2.cleared", "transactions.sp-parent.cleared", "transactions.sp-parent.imported_payee", "transactions.sp-parent.payee"],
    ]

    private static let op56Paths: [String: Set<String>] = [
        "gen-update-dates-001": ["transactions.ex-1.date", "transactions.ex-1a.date", "transactions.ex-1b.date"],
        "gen-update-dates-002": ["transactions.ex-1.date"],
        "gen-update-dates-007": ["transactions.ex-1.date"],
        "gen-update-dates-009": ["transactions.ex-1.date"],
        "gen-update-dates-010": ["transactions.ex-1.date"],
        "gen-update-dates-012": ["transactions.ex-1.date"],
        "gen-update-dates-013": ["transactions.ex-1.date"],
        "gen-update-dates-014": ["transactions.ex-1.date", "transactions.ex-1a.date", "transactions.ex-1b.date"],
        "gen-update-dates-015": ["transactions.ex-1.date"],
        "gen-update-dates-016": ["transactions.ex-1.date", "transactions.ex-1a.date", "transactions.ex-1b.date"],
        "gen-update-dates-018": ["transactions.ex-1.date"],
        "gen-update-dates-019": ["transactions.ex-1.date"],
        "gen-update-dates-020": ["transactions.ex-1.date"],
        "gen-update-dates-021": ["transactions.ex-1.date"],
        "gen-update-dates-023": ["transactions.ex-1.date", "transactions.ex-1a.date", "transactions.ex-1b.date"],
        "gen-update-dates-024": ["transactions.ex-1.date"],
        "gen-update-dates-025": ["transactions.ex-1.date"],
        "gen-update-dates-026": ["transactions.ex-1.date"],
        "gen-update-dates-027": ["transactions.ex-1.date"],
        "gen-update-dates-028": ["transactions.ex-1.date"],
        "gen-update-dates-029": ["transactions.ex-1.date"],
        "named-split-parent-match-cascades-date": ["transactions.sp-1.date", "transactions.sp-2.date", "transactions.sp-parent.date"],
        "named-update-dates-simplefin-pref": ["transactions.ex-1.date"],
        "named-update-dates-true": ["transactions.ex-1.date"],
    ]

    private static let op57Paths: [String: Set<String>] = [
        "gen-payee-name-002": ["transactions.ex-1.payee"],
        "gen-payee-name-013": ["transactions.ex-1.payee"],
        "gen-payee-name-018": ["transactions.ex-1.payee"],
        "gen-payee-name-022": ["transactions.ex-1.payee"],
        "gen-payee-name-023": ["transactions.ex-1.payee"],
        "gen-payee-name-027": ["transactions.ex-1.payee"],
        "gen-payee-name-029": ["transactions.ex-1.payee"],
        "gen-payee-name-033": ["transactions.ex-1.payee"],
        "gen-payee-name-037": ["transactions.ex-1.payee"],
        "gen-payee-name-039": ["transactions.ex-1.payee"],
        "gen-payee-name-042": ["transactions.ex-1.payee"],
        "gen-payee-name-044": ["transactions.ex-1.payee"],
        "gen-payee-name-046": ["transactions.ex-1.payee"],
        "named-payee-created-for-blank-match": ["transactions.ex-1.payee", "payees.new-payee:Brand New Shop"],
        "named-rule-changes-amount-then-match": ["transactions.ex-1.payee", "payees.new-payee:Fix Me"],
    ]

    private static let op58Paths: [String: Set<String>] = [
        "named-offbudget-match-rule-category": ["transactions.ex-1.category"],
    ]

    private static let op59Paths: [String: Set<String>] = [
        "named-opening-balance-pending-skipped": ["transactions.new-2.amount"],
        "named-opening-balance-rule-changes-amount": ["transactions.new-2.amount"],
    ]

    private static let op60Paths: [String: Set<String>] = [
        "named-opening-balance-date-from-last-row": ["transactions.new-3.date"],
    ]

    private static let op61Paths: [String: Set<String>] = [
        "gen-imported-id-004": ["result.skippedDeleted", "result.updated", "transactions.ex-1.imported_payee", "transactions.ex-1.payee"],
        "gen-imported-id-030": ["result.skippedDeleted", "result.updated", "transactions.ex-1.imported_payee"],
        "gen-imported-id-032": ["result.skippedDeleted", "result.updated", "transactions.ex-1.imported_payee", "transactions.ex-1.payee"],
        "gen-imported-id-035": ["result.skippedDeleted", "result.updated", "transactions.ex-1.imported_payee"],
        "named-commit": ["result.skippedDeleted", "result.updated", "transactions.ex-del.imported_payee", "transactions.ex-del.payee"],
        "named-preview": ["result.skippedDeleted", "result.updated"],
        "named-reimport-deleted-option-false": ["result.skippedDeleted", "result.updated", "transactions.ex-del.imported_payee", "transactions.ex-del.payee"],
        "named-reimport-deleted-simplefin-false": ["result.skippedDeleted", "result.updated", "transactions.ex-del.imported_payee"],
    ]

    private static let op62Paths: [String: Set<String>] = [
        "named-split-child-collision-with-parent-claimed": ["result.addedCount", "result.updated", "transactions.new-1", "transactions.sp-1.imported_payee", "transactions.sp-1.payee"],
    ]

    private static let op63Paths: [String: Set<String>] = [
        "named-rule-transfer-payee-matched-plain-row": ["transactions.ex-1.payee", "transactions.ex-1.transfer_id", "transactions.new-1"],
    ]

    private static let op64Paths: [String: Set<String>] = [
        "named-opening-balance-rule-deletes-row": ["payees.new-payee:Noise", "result.addedCount", "transactions.new-2.amount", "transactions.new-2.category", "transactions.new-2.imported_id", "transactions.new-2.imported_payee", "transactions.new-2.payee", "transactions.new-2.starting_balance_flag", "transactions.new-3"],
        "named-rule-delete-transaction-commit": ["payees.new-payee:Noise", "result.addedCount", "transactions.new-1.amount", "transactions.new-1.date", "transactions.new-1.imported_payee", "transactions.new-1.payee", "transactions.new-2"],
    ]

    private static let op65Paths: [String: Set<String>] = [
        "named-payee-matches-transfer-payee-name": ["candidate[0].imported_payee", "transactions.new-1.imported_payee"],
    ]

    private static let op66Paths: [String: Set<String>] = [
        "gen-payee-name-009": ["transactions.new-1.payee", "transactions.new-2.payee", "payees.new-payee:  padded name  ", "payees.new-payee:padded name"],
        "named-rule-imported-payee-simplefin": ["transactions.new-1.payee", "payees.new-payee:  WHOLE FOODS #123  ", "payees.new-payee:WHOLE FOODS #123"],
    ]

    private static let op67Paths: [String: Set<String>] = [
        "gen-multi-013": ["transactions.ex-3.imported_id", "transactions.ex-3.imported_payee", "transactions.ex-4.imported_id", "transactions.ex-4.imported_payee"],
        "gen-multi-029": ["result.updated[0]", "transactions.ex-1.imported_payee", "transactions.ex-1.payee", "transactions.ex-3.imported_payee", "transactions.ex-3.payee"],
        "gen-multi-044": ["result.updated[1]", "transactions.ex-2.imported_payee", "transactions.ex-3.imported_id", "transactions.ex-3.imported_payee", "transactions.ex-3.payee"],
        "gen-multi-045": ["result.ignored", "result.updated", "transactions.ex-4.imported_id", "transactions.ex-4.imported_payee", "transactions.ex-4.payee"],
        "gen-multi-052": ["result.updated[0]", "transactions.ex-1.imported_id", "transactions.ex-1.imported_payee", "transactions.ex-1.payee", "transactions.ex-2.imported_id", "transactions.ex-2.imported_payee", "transactions.ex-2.payee"],
        "gen-multi-055": ["result.ignored", "result.updated", "transactions.ex-4.imported_payee"],
    ]

    private static let op68Paths: [String: Set<String>] = [
        "gen-imported-id-008": ["result.updated[0]", "result.updated[1]", "transactions.ex-1.imported_payee", "transactions.ex-2.imported_payee", "transactions.ex-2.payee"],
    ]

    private static let op69Paths: [String: Set<String>] = [
        "gen-imported-id-039": ["result.addedCount", "result.updated", "transactions.ex-1.imported_payee", "transactions.new-1"],
        "named-reimport-deleted-pref-false-csv": ["result.addedCount", "result.updated", "transactions.ex-del.imported_payee", "transactions.ex-del.payee", "transactions.new-1"],
    ]
}
