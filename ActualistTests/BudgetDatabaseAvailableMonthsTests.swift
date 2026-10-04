import Foundation
import Testing
@testable import Actualist

@MainActor
struct BudgetDatabaseAvailableMonthsTests {
    private let support = LocalFirstActualStoreTests()

    /// Upstream builds the month range from the earliest row of the raw
    /// `transactions` table (`createAllBudgets`, budget/base.ts), so a deleted
    /// transaction still contributes its month. Envelope budgets keep it.
    @Test func envelopeMonthWithOnlyDeletedTransactionsStillAppears() async throws {
        let url = try support.makeSQLiteFixture(extraSQL: """
            INSERT INTO transactions (id, acct, date, amount, category, tombstone)
            VALUES ('gone', 'checking', 20261105, -500, 'groceries', 1);
            """)
        let database = try BudgetDatabase(databaseURL: url)

        #expect(try await database.fetchAvailableMonths() == ["2026-07", "2026-11"])
    }
}
