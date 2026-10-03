import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct BankSyncPostCommitTests {
    @Test func committedCancellationRetainsOutcomeWithoutBecomingUserFacingError() {
        let result = BankSyncReview.ApplyResult(insertedCount: 1, updatedCount: 0,
            openingBalanceInserted: false, insertedTransactionIDsByAccount: ["checking": ["saved"]])
        let error = BankSyncCommittedRefreshError(result: result, underlyingError: CancellationError())
        #expect(error.isCancellation)
        #expect(error.userFacingMessage == nil)
        #expect(error.result == result)
    }

    @Test func displayRefreshFailureRetainsCommittedOutcome() async throws {
        let support = LocalFirstActualStoreTests()
        let transport = LocalFirstActualStoreTests.StubSimpleFINTransport(
            response: .init(downloads: ["sfin-1": .init(
                transactions: [support.remoteTransaction(
                    id: "saved-before-refresh", amount: "-10.00",
                    dayID: "20260701", payeeName: "Coffee Shop"
                )], startingBalance: nil, errorType: nil, errorCode: nil
            )], errorType: nil, errorCode: nil)
        )
        let bundle = try await support.makeBankSyncStore(transport: transport)
        try await bundle.store.linkBankAccount("savings", to: support.remoteAccount(), budgetID: "group-1")
        // A selected month makes post-write reload read the budget identity.
        _ = try await bundle.store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let model = BankSyncViewModel(store: bundle.store, budgetID: "group-1", currency: .usd)
        await model.load()
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: "file-1").path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_display_after_commit AFTER UPDATE OF last_sync ON accounts
                WHEN NEW.id = 'savings'
                BEGIN DELETE FROM actualist_budget_identity; END;
                """)
        }
        await model.syncAll()
        guard case .failed(let message) = model.phase else {
            Issue.record("Expected committed refresh failure"); return
        }
        #expect(message.contains("saved locally"))
        #expect(model.lastRun?.summary.contains("Added 1 transaction") == true)
        #expect(model.resultLines.first?.addedCount == 1)
        #expect(try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions WHERE financial_id = 'saved-before-refresh'")
        } == 1)
    }
}
