import Foundation
import GRDB
import Testing
@testable import Actualist

/// A rule preview feeds Bank Sync's write plan, so a failed BALANCE_OF
/// prefetch must surface instead of evaluating every BALANCE_OF as 0.
@MainActor
@Suite("Rule preview BALANCE_OF failure")
struct RulePreviewBalanceOfFailureTests {
    private let support = LocalFirstActualStoreTests()

    @Test func unreadableBalanceDataThrowsInsteadOfPreviewingAZeroBalance() async throws {
        let url = try support.makeSQLiteFixture(extraSQL: #"""
            CREATE TABLE rules (
                id TEXT PRIMARY KEY, stage TEXT, conditions TEXT, actions TEXT,
                conditions_op TEXT DEFAULT 'and', tombstone INTEGER DEFAULT 0
            );
            INSERT INTO rules VALUES (
                'balance-rule', 'normal',
                '[{"op":"is","field":"acct","value":"checking"}]',
                '[{"op":"set","field":"amount","value":0,"options":{"formula":"=BALANCE_OF(\"Checking\")"}}]',
                'and', 0
            );
            """#)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "balance-failure-test")
        let date = try #require(ActualDateOnly.date(from: "2026-07-03", timeZone: ActualDateOnly.utc))
        let draft = TransactionDraft(
            accountID: "checking", date: date, amountMinorUnits: -100,
            payeeID: nil, payeeName: "", categoryID: nil, notes: nil,
            cleared: false, isTransfer: false
        )

        _ = try await database.previewRules(for: [draft], dateTimeZone: ActualDateOnly.utc)

        // The database caches table and column shapes after the first read, so
        // dropping the table now makes only the balance query fail.
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: "DROP TABLE transactions")
        }

        await #expect(throws: (any Error).self) {
            _ = try await database.previewRules(for: [draft], dateTimeZone: ActualDateOnly.utc)
        }
    }
}
