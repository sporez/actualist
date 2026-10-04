import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
@Suite("Action log and rule prefetch resilience")
struct ActionLogAndRulePrefetchResilienceTests {
    private let support = LocalFirstActualStoreTests()

    private static let actionLogSQL = """
        CREATE TABLE actualist_action_log (
            id TEXT PRIMARY KEY, created_at TEXT NOT NULL, kind TEXT NOT NULL,
            status TEXT NOT NULL, month TEXT, summary_json TEXT NOT NULL,
            inverse_json TEXT NOT NULL, affected_json TEXT NOT NULL,
            forward_ts_start TEXT, forward_ts_end TEXT, undone_at TEXT,
            undone_by_action_id TEXT, source TEXT NOT NULL, mode_identity_json TEXT
        );
        """

    private func insertAssignRows(
        count: Int,
        badKindAt badIndex: Int? = nil,
        into url: URL
    ) throws {
        let action = AssignBudgetAction(month: "2026-07", categoryID: "groceries", before: 0, after: 100)
        let summary = String(decoding: try JSONEncoder().encode(BudgetActionSummary.assign(action)), as: UTF8.self)
        let inverse = String(decoding: try JSONEncoder().encode(BudgetActionInverse.assign(action)), as: UTF8.self)
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            for index in 0..<count {
                let createdAt = SyncTimestamp.wallTimeString(for: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
                try db.execute(
                    sql: """
                        INSERT INTO actualist_action_log
                            (id, created_at, kind, status, month, summary_json, inverse_json, affected_json, source)
                        VALUES (?, ?, ?, 'applied', '2026-07', ?, ?, '["groceries"]', 'ui')
                        """,
                    arguments: ["row-\(index)", createdAt, index == badIndex ? "future_kind" : "assign", summary, inverse]
                )
            }
        }
    }

    @Test func historySkipsAnUndecodableRowAndKeepsValidRecords() async throws {
        let url = try support.makeSQLiteFixture(extraSQL: Self.actionLogSQL)
        try insertAssignRows(count: 4, badKindAt: 2, into: url)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "history-skip")

        let records = try await database.recentBudgetActions()
        #expect(records.map(\.id) == ["row-3", "row-1", "row-0"])
        let page = try await database.recentBudgetActionPage()
        #expect(page.records.count == 3)
        #expect(page.skippedRowCount == 1)
    }

    @Test func historyHonorsAnExplicitLimit() async throws {
        let url = try support.makeSQLiteFixture(extraSQL: Self.actionLogSQL)
        try insertAssignRows(count: 30, into: url)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "history-limit")

        #expect(try await database.recentBudgetActions(limit: 5).count == 5)
    }

    /// Two Int64.max amounts make SQLite's SUM raise `integer overflow`.
    @Test func balanceOfPrefetchFailureThrowsInsteadOfBecomingZero() async throws {
        let url = try support.makeSQLiteFixture(extraSQL: #"""
            INSERT INTO transactions (id, acct, date, amount, tombstone, is_parent)
            VALUES ('overflow-a', 'checking', 20260702, 9223372036854775807, 0, 0),
                   ('overflow-b', 'checking', 20260702, 9223372036854775807, 0, 0);
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
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "balance-throws")
        let draft = TransactionDraft(
            accountID: "checking",
            date: try #require(ActualDateOnly.date(from: "2026-07-03", timeZone: ActualDateOnly.utc)),
            amountMinorUnits: -100, payeeID: nil, payeeName: "", categoryID: nil, notes: nil,
            cleared: false, isTransfer: false
        )

        await #expect(throws: (any Error).self) {
            _ = try await database.previewRules(for: [draft], dateTimeZone: ActualDateOnly.utc)
        }
    }

    @Test func directBalanceOfPrefetchPropagatesQueryFailure() async throws {
        let url = try support.makeSQLiteFixture(extraSQL: """
            INSERT INTO transactions (id, acct, date, amount, tombstone, is_parent)
            VALUES ('overflow-a', 'checking', 20260702, 9223372036854775807, 0, 0),
                   ('overflow-b', 'checking', 20260702, 9223372036854775807, 0, 0);
            """)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "diag")
        let date = try #require(ActualDateOnly.date(from: "2026-07-03", timeZone: ActualDateOnly.utc))
        await #expect(throws: (any Error).self) {
            _ = try await database.prefetchBalanceOf(
                formulas: [#"=BALANCE_OF("Checking")"#], date: date, sortOrder: nil,
                excludingTransactionID: nil, dateTimeZone: ActualDateOnly.utc
            )
        }
    }
}
