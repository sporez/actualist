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
            OracleJSONFileCache.jsonObject(at: url),
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
        // A listed case always runs its known-issue block, so a divergence that stops occurring
        // fails until its table entry, marker and registry entry are removed together.
        var remaining = comparison.mismatches
        func take(_ table: [String: Set<String>]) -> [ReplayMismatch]? {
            guard let paths = table[caseID] else { return nil }
            let split = KnownDivergenceSplit(remaining, knownPaths: paths)
            remaining = split.strict
            return split.known
        }

        let op58 = take(Self.op58Paths)
        let op59 = take(Self.op59Paths)
        let op60 = take(Self.op60Paths)
        let op61 = take(Self.op61Paths)
        let op62 = take(Self.op62Paths)
        let op66 = take(Self.op66Paths)
        let op68 = take(Self.op68Paths)
        let op123 = take(Self.op123Paths)
        let op124 = take(Self.op124Paths)
        let op125 = take(Self.op125Paths)
        let op126 = take(Self.op126Paths)

        #expect(remaining.isEmpty, Comment(rawValue: OracleComparison.report(caseID, remaining)))
        if let op58 {
            withKnownIssue("OP-58: a matched off-budget row never takes a category, where the oracle fills it") {
                #expect(op58.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op58)))
            }
        }
        if let op59 {
            withKnownIssue("OP-59: the opening balance is derived from planned inserts, where the oracle subtracts the raw download") {
                #expect(op59.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op59)))
            }
        }
        if let op60 {
            withKnownIssue("OP-60: the opening balance takes the earliest download day, where the oracle takes the last row's date") {
                #expect(op60.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op60)))
            }
        }
        if let op61 {
            withKnownIssue("OP-61: a deleted row's ID is skipped, where the oracle matches and rewrites the deleted row") {
                #expect(op61.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op61)))
            }
        }
        if let op62 {
            withKnownIssue("OP-62: children of an ID-matched split parent are reserved, where the pinned oracle lets a download match one") {
                #expect(op62.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op62)))
            }
        }
        if let op66 {
            withKnownIssue("OP-66: a padded provider payee name is created trimmed, where the oracle keeps the spaces") {
                #expect(op66.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op66)))
            }
        }
        if let op68 {
            withKnownIssue("OP-68: a duplicated provider ID matches a different row than the oracle's") {
                #expect(op68.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op68)))
            }
        }
        if let op123 {
            withKnownIssue("OP-123: an Enable Banking row in another currency blocks the account, where the oracle imports it") {
                #expect(op123.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op123)))
            }
        }
        if let op124 {
            withKnownIssue("OP-124: an Enable Banking row without an ID stores no imported ID, where the oracle stores an empty one") {
                #expect(op124.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op124)))
            }
        }
        if let op125 {
            withKnownIssue("OP-125: an Enable Banking row without a payee blocks the account, where the oracle imports it") {
                #expect(op125.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op125)))
            }
        }
        if let op126 {
            withKnownIssue("OP-126: no bank balance clears the account balance, where the oracle stores 0") {
                #expect(op126.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op126)))
            }
        }
    }

    // MARK: Known divergences (config/parity/known-divergences.json)

    private static let op58Paths: [String: Set<String>] = [
        "named-offbudget-match-rule-category": ["transactions.ex-1.category"],
    ]

    private static let op59Paths: [String: Set<String>] = [
        "named-opening-balance-pending-skipped": ["transactions.new-2.amount"],
        "named-opening-balance-rule-deletes-row": ["transactions.new-2.amount"],
        "named-opening-balance-rule-changes-amount": ["transactions.new-2.amount"],
    ]

    private static let op60Paths: [String: Set<String>] = [
        "named-opening-balance-date-from-last-row": ["transactions.new-3.date"],
        "named-enablebanking-opening-balance-pending-off": ["transactions.new-3.date"],
    ]

    private static let op61Paths: [String: Set<String>] = [
        "gen-imported-id-004": ["result.skippedDeleted", "result.updated", "transactions.ex-1.imported_payee", "transactions.ex-1.payee"],
        "gen-imported-id-030": ["result.skippedDeleted", "result.updated", "transactions.ex-1.imported_payee"],
        "gen-imported-id-032": ["result.skippedDeleted", "result.updated", "transactions.ex-1.imported_payee", "transactions.ex-1.payee"],
        "gen-imported-id-035": ["result.skippedDeleted", "result.updated", "transactions.ex-1.imported_payee"],
        "gen-imported-id-039": ["result.skippedDeleted", "result.updated", "transactions.ex-1.imported_payee"],
        "named-commit": ["result.skippedDeleted", "result.updated", "transactions.ex-del.imported_payee", "transactions.ex-del.payee"],
        "named-preview": ["result.skippedDeleted", "result.updated"],
        "named-reimport-deleted-pref-false-csv": ["result.skippedDeleted", "result.updated", "transactions.ex-del.imported_payee", "transactions.ex-del.payee"],
        "named-reimport-deleted-option-false": ["result.skippedDeleted", "result.updated", "transactions.ex-del.imported_payee", "transactions.ex-del.payee"],
        "named-reimport-deleted-simplefin-false": ["result.skippedDeleted", "result.updated", "transactions.ex-del.imported_payee"],
    ]

    private static let op62Paths: [String: Set<String>] = [
        "named-split-child-collision-with-parent-claimed": ["result.addedCount", "result.updated", "transactions.new-1", "transactions.sp-1.imported_payee", "transactions.sp-1.payee"],
    ]

    private static let op66Paths: [String: Set<String>] = [
        "gen-payee-name-009": ["transactions.new-1.payee", "transactions.new-2.payee", "payees.new-payee:  padded name  ", "payees.new-payee:padded name"],
        "named-rule-imported-payee-simplefin": ["transactions.new-1.payee", "payees.new-payee:  WHOLE FOODS #123  ", "payees.new-payee:WHOLE FOODS #123"],
    ]

    private static let op123Paths: [String: Set<String>] = [
        "named-enablebanking-currency-mismatch": [
            "problems", "candidates", "balance_current", "result.addedCount", "transactions.new-1",
            "payees.new-payee:Synthetic London Shop",
        ],
    ]

    /// The blank ID sorts before the others, so the content-derived names of every new row shift.
    private static let op124Paths: [String: Set<String>] = [
        "named-enablebanking-empty-ids-match-existing": ["candidate[2].imported_id", "candidate[3].imported_id"],
        "named-enablebanking-empty-transaction-id": ["candidate[2].imported_id", "candidate[3].imported_id", "transactions.new-1.amount", "transactions.new-1.date", "transactions.new-1.imported_id", "transactions.new-1.imported_payee", "transactions.new-1.payee", "transactions.new-2.amount", "transactions.new-2.date", "transactions.new-2.imported_id", "transactions.new-2.imported_payee", "transactions.new-2.payee", "transactions.new-3.amount", "transactions.new-3.date", "transactions.new-3.imported_id", "transactions.new-3.imported_payee", "transactions.new-3.payee", "transactions.new-4.amount", "transactions.new-4.date", "transactions.new-4.imported_id", "transactions.new-4.imported_payee", "transactions.new-4.payee"],
    ]

    private static let op125Paths: [String: Set<String>] = [
        "named-enablebanking-payee-and-sign": ["problems", "candidates", "result.addedCount", "transactions.new-5"],
    ]

    private static let op126Paths: [String: Set<String>] = [
        "named-enablebanking-empty-balances": ["balance_current"],
    ]

    private static let op68Paths: [String: Set<String>] = [
        "gen-imported-id-008": ["result.updated[0]", "result.updated[1]", "transactions.ex-1.imported_payee", "transactions.ex-2.imported_payee", "transactions.ex-2.payee"],
    ]
}
