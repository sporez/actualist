import Foundation
import GRDB
import Testing
@testable import Actualist

/// A zero-amount download. The pinned Actual adds it like any other row
/// (Bank Sync oracle case `named-provider-zero-amount`, oracle-only because
/// the replay skips provider mapping).
@MainActor
struct BankSyncZeroAmountDownloadTests {
    private let support = LocalFirstActualStoreTests()

    private func fixture() async throws -> (LocalFirstActualStoreTests.OpenedWritableStoreBundle, DatabaseQueue) {
        let remote = SimpleFINRemoteAccount(
            accountID: "bank-account", name: "Checking", balance: "100.00", currency: "USD",
            institution: nil, orgName: "Fixture Bank", orgDomain: "bank.example", orgID: nil
        )
        let transactions = [
            SimpleFINRemoteTransaction(
                id: "bank-zero", dateUnixSeconds: 1_783_000_000, amount: "0.00",
                currency: "USD", payeeName: "Card Verification", notes: nil, booked: true,
                accountID: remote.accountID
            ),
            SimpleFINRemoteTransaction(
                id: "bank-coffee", dateUnixSeconds: 1_783_000_000, amount: "-10.00",
                currency: "USD", payeeName: "Coffee Shop", notes: nil, booked: true,
                accountID: remote.accountID
            ),
        ]
        let transport = LocalFirstActualStoreTests.StubSimpleFINTransport(
            remoteAccounts: [remote],
            response: SimpleFINTransactionsResponse(
                downloads: [remote.accountID: SimpleFINAccountDownload(
                    transactions: transactions, startingBalance: 10_000,
                    errorType: nil, errorCode: nil
                )], errorType: nil, errorCode: nil
            )
        )
        let bundle = try await support.makeOpenedWritableStoreBundle(
            simpleFINTransportFactory: { _ in transport },
            pendingLocalMessageFlushRetryDelays: [],
            additionalFixtureSQL: LocalFirstActualStoreTests.bankSyncColumnsSQL
        )
        bundle.store.openedServerURLString = "https://sync.example"
        try bundle.keychain.saveActualSyncToken("test-sync-token")
        let queue = await (try bundle.store.requireDatabase(for: "group-1")).queue
        try await bundle.store.linkBankAccount("savings", to: remote, budgetID: "group-1")
        return (bundle, queue)
    }

    @Test func aZeroAmountDownloadIsAddedLikeActual() async throws {
        let (bundle, queue) = try await fixture()

        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(plan.inserts.compactMap(\.financialID).sorted() == ["bank-coffee", "bank-zero"])
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")

        let zero = try await queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT amount FROM transactions
                WHERE acct = 'savings' AND financial_id = 'bank-zero' AND IFNULL(tombstone, 0) = 0
                """)
        }
        #expect(zero == 0)
        let coffee = try await queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT amount FROM transactions
                WHERE acct = 'savings' AND financial_id = 'bank-coffee' AND IFNULL(tombstone, 0) = 0
                """)
        }
        #expect(coffee == -1_000)
    }

    /// The background path (Background Bank Sync) applies without a review.
    @Test func aZeroAmountDownloadDoesNotFailBackgroundBankSync() async throws {
        let (bundle, queue) = try await fixture()

        _ = try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")

        let rows = try await queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT financial_id FROM transactions
                WHERE acct = 'savings' AND financial_id IS NOT NULL AND IFNULL(tombstone, 0) = 0
                ORDER BY financial_id
                """)
        }
        #expect(rows == ["bank-coffee", "bank-zero"])
    }
}
