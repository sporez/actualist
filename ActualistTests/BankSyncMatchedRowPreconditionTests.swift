import Foundation
import Testing
@testable import Actualist

/// Concurrency 5.2c (audit CA-12): Apply must not overwrite a matched row the
/// user (or a sync) edited after the review was built.
extension LocalFirstActualStoreTests {
    @Test func applyRefusesAMatchedRowEditedAfterTheReview() async throws {
        let transport = StubSimpleFINTransport(
            remoteAccounts: [remoteAccount(balance: "0.00")],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    "sfin-1": SimpleFINAccountDownload(
                        transactions: [
                            remoteTransaction(id: "d1", amount: "-10.00", dayID: "20260701", payeeName: "Coffee Shop")
                        ],
                        startingBalance: nil,
                        errorType: nil,
                        errorCode: nil
                    )
                ],
                errorType: nil,
                errorCode: nil
            )
        )
        let bundle = try await makeBankSyncStore(
            transport: transport,
            additionalFixtureSQL: """
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent)
                VALUES ('hand-1', 'savings', 20260701, -1000, NULL, 0, 'coffee', NULL, 0, 0);
                """
        )
        let store = bundle.store
        try await store.linkBankAccount("savings", to: remoteAccount(), budgetID: "group-1")
        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        let plan = try await store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(plan.updates.first?.existingID == "hand-1")

        // The user edits the matched row while the review sheet is open.
        let database = try store.requireDatabase(for: "group-1")
        _ = try await database.applyRemoteSyncMessages([
            ActualSyncDecodedMessage(
                timestamp: "2026-07-04T12:00:00.000Z-0000-peernode0000001",
                dataset: "transactions",
                row: "hand-1",
                column: "notes",
                serializedValue: "S:edited after review"
            )
        ])

        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.staleGeneration) {
            try await store.applyBankSyncPlan(plan, budgetID: "group-1")
        }
        #expect(!(try storedCRDTMessages(at: databaseURL)).contains {
            $0.dataset == "transactions" && $0.row == "hand-1" && $0.column == "financial_id"
        })
    }
}
