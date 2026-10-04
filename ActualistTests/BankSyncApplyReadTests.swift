import Foundation
import GRDB
import Testing
@testable import Actualist

/// Phase 5.4: Bank Sync apply reads existing rows only for the matched
/// updates it will rewrite, and only those rows. The unfiltered read is the
/// oracle for the by-id read.
@MainActor
struct BankSyncApplyReadTests {
    private let fixtures = LocalFirstActualStoreTests()
    private static let existingRowsMarker = "AS financial_id"

    private func transport(transactions: [SimpleFINRemoteTransaction]) -> LocalFirstActualStoreTests.StubSimpleFINTransport {
        .init(
            remoteAccounts: [fixtures.remoteAccount(balance: "0.00")],
            response: SimpleFINTransactionsResponse(
                downloads: ["sfin-1": SimpleFINAccountDownload(
                    transactions: transactions, startingBalance: nil, errorType: nil, errorCode: nil)],
                errorType: nil,
                errorCode: nil
            )
        )
    }

    @Test func existingRowsByIDMatchTheUnfilteredReadFilteredByID() async throws {
        let bundle = try await fixtures.makeBankSyncStore(transport: transport(transactions: []))
        let database = try #require(bundle.store.database)
        let queue = await database.queue
        try await queue.write { db in
            for index in 0..<1_300 {
                try db.execute(sql: """
                    INSERT INTO transactions (id, acct, date, amount, category, tombstone, is_parent, financial_id, notes, cleared)
                    VALUES (?, ?, ?, ?, NULL, ?, 0, ?, ?, ?)
                    """, arguments: [
                        "row-\(index)", index % 7 == 0 ? "checking" : "savings", 20_260_000 + 101 + index % 28,
                        -100 * (index % 9), index % 11 == 0 ? 1 : 0, index % 5 == 0 ? "fin-\(index)" : nil,
                        index % 3 == 0 ? "note \(index)" : nil, index % 2
                    ])
            }
        }
        let window = 0...99_999_999
        let all = try await database.bankSyncExistingRows(accountID: "savings", window: window)
        #expect(all.count > 900)
        let wanted = (0..<1_300).filter { $0 % 4 != 1 }.map { "row-\($0)" } + ["missing-1", "row-0"]
        let log = StatementLog()
        try await database.startStatementTraceForTesting(log)
        let byID = try await database.bankSyncExistingRows(accountID: "savings", window: window, ids: wanted)
        try await database.stopStatementTraceForTesting()
        let expected = all.filter { Set(wanted).contains($0.id) }
        #expect(Set(byID.map(\.id)) == Set(expected.map(\.id)))
        #expect(byID.sorted { $0.id < $1.id } == expected.sorted { $0.id < $1.id })
        #expect(!byID.isEmpty)
        // Wrong-account and tombstoned rows stay excluded (row-0 is "checking").
        #expect(!byID.contains { $0.id == "row-0" })
        // Work count: 975+ ids read in chunks of 500, never the whole account.
        #expect(log.count(containing: Self.existingRowsMarker) == 2)
        #expect(try await database.bankSyncExistingRows(accountID: "savings", window: window, ids: []).isEmpty)
    }

    @Test func applyReadsNoExistingRowsWithoutUpdatesAndOneFilteredReadWithUpdates() async throws {
        let withoutUpdates = try await fixtures.makeBankSyncStore(transport: transport(transactions: [
            fixtures.remoteTransaction(id: "d1", amount: "-10.00", dayID: "20260701", payeeName: "Coffee Shop")
        ]))
        try await withoutUpdates.store.linkBankAccount("savings", to: fixtures.remoteAccount(), budgetID: "group-1")
        let plan = try await withoutUpdates.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(plan.updates.isEmpty)
        #expect(!plan.inserts.isEmpty)
        let database = try #require(withoutUpdates.store.database)
        let log = StatementLog()
        try await database.startStatementTraceForTesting(log)
        _ = try await withoutUpdates.store.applyBankSyncPlan(plan, budgetID: "group-1")
        try await database.stopStatementTraceForTesting()
        #expect(log.count(containing: Self.existingRowsMarker) == 0)

        let withUpdate = try await fixtures.makeBankSyncStore(
            transport: transport(transactions: [
                fixtures.remoteTransaction(id: "d1", amount: "-10.00", dayID: "20260701", payeeName: "Coffee Shop")
            ]),
            additionalFixtureSQL: """
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent)
                VALUES ('hand-1', 'savings', 20260701, -1000, NULL, 0, 'coffee', NULL, 0, 0);
                """
        )
        try await withUpdate.store.linkBankAccount("savings", to: fixtures.remoteAccount(), budgetID: "group-1")
        let updatePlan = try await withUpdate.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(updatePlan.updates.count == 1)
        let updateDatabase = try #require(withUpdate.store.database)
        let updateLog = StatementLog()
        try await updateDatabase.startStatementTraceForTesting(updateLog)
        _ = try await withUpdate.store.applyBankSyncPlan(updatePlan, budgetID: "group-1")
        try await updateDatabase.stopStatementTraceForTesting()
        #expect(updateLog.count(containing: Self.existingRowsMarker, "t.id IN (") == 1)
        #expect(updateLog.count(containing: Self.existingRowsMarker) == 1)
    }
}
