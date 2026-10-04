import Foundation
import GRDB
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    private func insertRemoteImportedRow(at url: URL, id: String, account: String, financialID: String) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transactions (id, acct, date, amount, financial_id, tombstone)
                    VALUES (?, ?, 20260701, -1000, ?, 0)
                    """,
                arguments: [id, account, financialID]
            )
        }
    }

    private func importedRowCount(at url: URL, financialID: String) throws -> Int {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transactions WHERE financial_id = ?",
                arguments: [financialID]
            ) ?? 0
        }
    }

    private func walletCandidate(_ uuid: String, merchant: String) throws -> WalletTransactionCandidate {
        let id = try #require(UUID(uuidString: uuid))
        let date = try makeDate(year: 2026, month: 7, day: 18)
        return try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: id,
                    amount: Decimal(string: "3.00")!,
                    creditDebitIndicator: .debit,
                    merchantName: merchant,
                    transactionDescription: merchant,
                    transactionDate: date,
                    status: .booked
                )
            )
        )
    }

    @Test func bankSyncApplyThrowsStaleWhenARemoteRowWithTheSameFinancialIDLandedFirst() async throws {
        let transport = StubSimpleFINTransport(
            remoteAccounts: [remoteAccount(balance: "0.00")],
            response: SimpleFINTransactionsResponse(
                downloads: ["sfin-1": SimpleFINAccountDownload(
                    transactions: [remoteTransaction(
                        id: "d1", amount: "-10.00", dayID: "20260701", payeeName: "Coffee Shop"
                    )],
                    startingBalance: nil, errorType: nil, errorCode: nil
                )],
                errorType: nil, errorCode: nil
            )
        )
        let bundle = try await makeBankSyncStore(transport: transport)
        try await bundle.store.linkBankAccount("savings", to: remoteAccount(), budgetID: "group-1")
        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(plan.inserts.compactMap(\.financialID) == ["d1"])
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        try insertRemoteImportedRow(at: url, id: "remote-row", account: "savings", financialID: "d1")

        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.staleGeneration) {
            try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        }

        #expect(try importedRowCount(at: url, financialID: "d1") == 1)
    }

    @Test func walletImportRetriesOnceWithAFreshReadAndCountsTheLandedRowAsDuplicate() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.walletImportColumnsSQL)
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        let uuid = "11111111-2222-3333-4444-555555555555"
        let candidate = try walletCandidate(uuid, merchant: "Retry Cafe")
        bundle.store.walletImportBeforeCommitHook = { attempt in
            guard attempt == 1 else { return }
            do {
                try self.insertRemoteImportedRow(
                    at: url, id: "remote-row", account: "checking", financialID: uuid
                )
            } catch {
                Issue.record("could not land the remote row: \(error)")
            }
        }

        let result = try await bundle.store.importWalletTransactions(
            [candidate], intoAccountID: "checking", budgetID: "group-1"
        )

        #expect(result == WalletTransactionImportResult(importedCount: 0, duplicateCount: 1))
        #expect(try importedRowCount(at: url, financialID: uuid) == 1)
    }

    @Test func walletImportReportsASecondConflictWithoutDuplicating() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.walletImportColumnsSQL)
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        let firstUUID = "11111111-2222-3333-4444-555555555555"
        let secondUUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let candidates = [
            try walletCandidate(firstUUID, merchant: "First Cafe"),
            try walletCandidate(secondUUID, merchant: "Second Cafe"),
        ]
        bundle.store.walletImportBeforeCommitHook = { attempt in
            do {
                try self.insertRemoteImportedRow(
                    at: url,
                    id: "remote-\(attempt)",
                    account: "checking",
                    financialID: attempt == 1 ? firstUUID : secondUUID
                )
            } catch {
                Issue.record("could not land the remote row: \(error)")
            }
        }

        await #expect(throws: LocalFirstError.importedTransactionConflict) {
            _ = try await bundle.store.importWalletTransactions(
                candidates, intoAccountID: "checking", budgetID: "group-1"
            )
        }

        #expect(try importedRowCount(at: url, financialID: firstUUID) == 1)
        #expect(try importedRowCount(at: url, financialID: secondUUID) == 1)
    }
}
