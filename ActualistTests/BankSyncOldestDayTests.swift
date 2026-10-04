import Foundation
import Testing
@testable import Actualist

@MainActor
struct BankSyncOldestDayTests {
    private let fixtures = LocalFirstActualStoreTests()

    @Test func oldestLiveDayUsesTheAlternativeAccountColumn() async throws {
        let url = try fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions RENAME COLUMN acct TO account;
            INSERT INTO transactions (id, account, date, amount, tombstone)
                VALUES ('older', 'checking', 20260215, 100, 0),
                       ('deleted', 'checking', 20250101, 100, 1),
                       ('other', 'savings', 20240101, 100, 0);
            """)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node1")

        #expect(try await database.bankSyncOldestLiveTransactionDayID(accountID: "checking") == "20260215")
        #expect(try await database.bankSyncOldestLiveTransactionDayID(accountID: "nobody") == nil)
    }

    @Test func oldestLiveDayStillWorksWithTheAcctColumn() async throws {
        let url = try fixtures.makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node1")

        #expect(try await database.bankSyncOldestLiveTransactionDayID(accountID: "checking") == "20260703")
    }
}
