import Foundation
import Testing
@testable import Actualist

/// Replays the Transactions oracle contract (manual, transfer, import and starting-balance creation)
/// through the production creation writers. One replay test covers every case id; the partition
/// test accounts for the manifest. Schedule posting is owned by `ScheduleOracleReplayTests`.
@MainActor
struct TransactionCreateOracleReplayTests {
    private static let domain = "Transactions"
    private static let fileName = "transactions-contract.json"
    private static let manifestName = "transactions-manifest.json"

    /// Read by the `@Test(arguments:)` macro outside the suite's main-actor isolation.
    nonisolated private static let replayedCaseIDs = [
        "manual-payee-category-notes-cleared",
        "manual-payee-category-uncleared-no-notes",
        "manual-no-payee",
        "manual-no-category",
        "manual-no-payee-no-category",
        "manual-new-payee",
        "manual-income-category",
        "manual-off-budget-account",
        "manual-off-budget-account-category-supplied",
        "transfer-on-to-on",
        "transfer-on-to-on-category-supplied",
        "transfer-on-to-off",
        "transfer-on-to-off-no-category",
        "transfer-off-to-on",
        "transfer-off-to-off",
        "import-new-row-with-identity",
        "import-new-row-existing-payee-uncleared",
        "import-new-row-no-payee-no-identity",
        "import-new-row-off-budget-account",
        "starting-balance-on-budget",
        "starting-balance-off-budget",
    ]

    /// Open divergences that account for each case's differences (config/parity/known-divergences.json).
    /// `TransactionCreateOracleReplay.divergence(for:caseID:)` attributes every difference to one of
    /// them; a difference no listed divergence accounts for fails strictly, and each listed
    /// divergence runs inside `withKnownIssue`, so a fix makes its marker fail until it is removed.
    nonisolated private static let knownDivergences: [String: [String]] = [
        "manual-payee-category-notes-cleared": ["OP-80", "OP-82", "OP-83"],
        "manual-payee-category-uncleared-no-notes": ["OP-80", "OP-81", "OP-82", "OP-83"],
        "manual-no-payee": ["OP-84"],
        "manual-no-category": ["OP-80", "OP-81", "OP-82", "OP-83"],
        "manual-no-payee-no-category": ["OP-84"],
        "manual-new-payee": ["OP-80", "OP-81", "OP-82", "OP-83"],
        "manual-income-category": ["OP-80", "OP-81", "OP-82", "OP-83"],
        "manual-off-budget-account": ["OP-80", "OP-81", "OP-82", "OP-83"],
        "manual-off-budget-account-category-supplied": ["OP-80", "OP-81", "OP-82", "OP-83"],
        "transfer-on-to-on": ["OP-80", "OP-81", "OP-82", "OP-83"],
        "transfer-on-to-on-category-supplied": ["OP-80", "OP-81", "OP-82", "OP-83", "OP-86"],
        "transfer-on-to-off": ["OP-80", "OP-81", "OP-82", "OP-83"],
        "transfer-on-to-off-no-category": ["OP-80", "OP-81", "OP-82", "OP-83"],
        "transfer-off-to-on": ["OP-80", "OP-81", "OP-82", "OP-83", "OP-86"],
        "transfer-off-to-off": ["OP-80", "OP-81", "OP-82", "OP-83"],
        "import-new-row-with-identity": ["OP-80", "OP-81", "OP-83"],
        "import-new-row-existing-payee-uncleared": ["OP-80", "OP-81", "OP-83"],
        "import-new-row-no-payee-no-identity": ["OP-80", "OP-81", "OP-83"],
        "import-new-row-off-budget-account": ["OP-80", "OP-81", "OP-83"],
        "starting-balance-on-budget": ["OP-80", "OP-81", "OP-82", "OP-83", "OP-85"],
        "starting-balance-off-budget": ["OP-80", "OP-81", "OP-82", "OP-83"],
    ]

    @Test
    func manifestPartitionsEveryContractCase() throws {
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "expected")
        let manifest = try OracleManifest(domain: Self.domain, manifestName: Self.manifestName, fileName: Self.fileName)
        let problems = manifest.partitionProblems(fixtureIDs: cases.ids, replayed: Self.replayedCaseIDs)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
        #expect(Set(Self.knownDivergences.keys).isSubset(of: Set(Self.replayedCaseIDs)))
    }

    @Test(arguments: replayedCaseIDs)
    func replaysCreateCase(caseID: String) async throws {
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "expected")
        let result = try await TransactionCreateOracleReplay.replay(try cases.entry(caseID)) {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "TransactionCreateReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        let listed = Self.knownDivergences[caseID] ?? []
        var byDivergence: [String: [TransactionCreateOracleReplay.Difference]] = [:]
        var strict: [TransactionCreateOracleReplay.Difference] = []
        for difference in result.differences {
            if let id = TransactionCreateOracleReplay.divergence(for: difference, caseID: caseID), listed.contains(id) {
                byDivergence[id, default: []].append(difference)
            } else {
                strict.append(difference)
            }
        }
        func report(_ differences: [TransactionCreateOracleReplay.Difference]) -> Comment {
            Comment(rawValue: ([caseID] + differences.map(\.line)).joined(separator: "\n  "))
        }
        #expect(strict.isEmpty, report(strict))
        if listed.contains("OP-80") {
            withKnownIssue("OP-80: creation writes tombstone, isParent, parent_id, isChild, error cells that Actual leaves to column defaults") {
                #expect((byDivergence["OP-80"] ?? []).isEmpty, report(byDivergence["OP-80"] ?? []))
            }
        }
        if listed.contains("OP-81") {
            withKnownIssue("OP-81: creation writes explicit null cells for unset notes, category and payee where Actual writes nothing") {
                #expect((byDivergence["OP-81"] ?? []).isEmpty, report(byDivergence["OP-81"] ?? []))
            }
        }
        if listed.contains("OP-82") {
            withKnownIssue("OP-82: manual, transfer and starting-balance creation write no sort_order, where Actual always writes one") {
                #expect((byDivergence["OP-82"] ?? []).isEmpty, report(byDivergence["OP-82"] ?? []))
            }
        }
        if listed.contains("OP-83") {
            withKnownIssue("OP-83: creation never writes reconciled = 0, where Actual writes it on every new row") {
                #expect((byDivergence["OP-83"] ?? []).isEmpty, report(byDivergence["OP-83"] ?? []))
            }
        }
        if listed.contains("OP-84") {
            withKnownIssue("OP-84: a manual create without a payee is refused, where Actual writes the transaction without one") {
                #expect((byDivergence["OP-84"] ?? []).isEmpty, report(byDivergence["OP-84"] ?? []))
            }
        }
        if listed.contains("OP-85") {
            withKnownIssue("OP-85: the starting-balance row takes the first income category, where Actual takes the one named Starting Balances") {
                #expect((byDivergence["OP-85"] ?? []).isEmpty, report(byDivergence["OP-85"] ?? []))
            }
        }
        if listed.contains("OP-86") {
            withKnownIssue("OP-86: a category on a cross-budget transfer lands on the paired on-budget leg, and one supplied on an on-budget to on-budget transfer is never written, where Actual writes then clears it or drops it") {
                #expect((byDivergence["OP-86"] ?? []).isEmpty, report(byDivergence["OP-86"] ?? []))
            }
        }
    }
}
