import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct AccountLifecycleFreshnessTests {
    private let support = LocalFirstActualStoreTests()

    @Test func everyReviewedCloseFactRejectsChangesWithoutWrites() async throws {
        let mutations: [(name: String, sql: String)] = [
            ("transaction graph", "UPDATE transactions SET notes = 'peer note' WHERE id = 'txn';"),
            ("source facts", "UPDATE accounts SET name = 'Peer Checking' WHERE id = 'checking';"),
            ("destination facts", "UPDATE accounts SET name = 'Peer Destination' WHERE id = 'destination';"),
            ("category facts", "UPDATE categories SET name = 'Peer Groceries' WHERE id = 'groceries';"),
            (
                "bank link",
                """
                UPDATE accounts
                SET account_id = 'remote', account_sync_source = 'simpleFin', bank = 'bank'
                WHERE id = 'checking';
                """
            ),
            (
                "schedule digest",
                """
                INSERT INTO rules VALUES (
                    'schedule-rule',
                    '[{"field":"acct","op":"is","value":"checking"}]',
                    '[{"op":"link-schedule","value":"schedule"}]',
                    0
                );
                INSERT INTO schedules VALUES ('schedule', 'Peer Schedule', 'schedule-rule', 0, 0);
                """
            ),
        ]

        for mutation in mutations {
            let fixture = try makeFixture()
            let reviewed = try await fixture.database.accountLifecycleReview(
                request: closeRequest,
                localDay: testDay
            )
            let clockBefore = await fixture.database.localClock
            let queue = try DatabaseQueue(path: fixture.url.path)
            try queue.write { db in
                try db.execute(sql: mutation.sql)
            }

            let result = try await fixture.database.commitAccountLifecycleReview(
                reviewed,
                localDay: { self.testDay }
            )

            guard case .reviewChanged(let fresh) = result else {
                Issue.record("Expected replacement review after changed \(mutation.name)")
                continue
            }
            #expect(fresh.identity != reviewed.identity)
            #expect(try await fixture.database.pendingLocalSyncMessageCount() == 0)
            #expect(try await fixture.database.recentBudgetActions().isEmpty)
            #expect(await fixture.database.localClock == clockBefore)
            #expect(try await fixture.database.fetchAccounts().first { $0.id == "checking" }?.closed == false)
        }
    }

    private func makeFixture() throws -> (database: BudgetDatabase, url: URL) {
        let url = try support.makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions ADD COLUMN description TEXT;
            ALTER TABLE transactions ADD COLUMN notes TEXT;
            ALTER TABLE transactions ADD COLUMN isChild INTEGER;
            ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
            ALTER TABLE transactions ADD COLUMN cleared INTEGER;
            INSERT INTO accounts VALUES ('destination', 'Destination', 1, 0, 0, 2);
            CREATE TABLE payees (
                id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER
            );
            INSERT INTO payees VALUES ('transfer-checking', '', 'checking', 0);
            INSERT INTO payees VALUES ('transfer-destination', '', 'destination', 0);
            ALTER TABLE accounts ADD COLUMN account_id TEXT;
            ALTER TABLE accounts ADD COLUMN account_sync_source TEXT;
            ALTER TABLE accounts ADD COLUMN bank TEXT;
            ALTER TABLE accounts ADD COLUMN balance_current INTEGER;
            ALTER TABLE accounts ADD COLUMN balance_available INTEGER;
            ALTER TABLE accounts ADD COLUMN balance_limit INTEGER;
            ALTER TABLE accounts ADD COLUMN bank_sync_status TEXT;
            CREATE TABLE rules (
                id TEXT PRIMARY KEY, conditions TEXT, actions TEXT, tombstone INTEGER
            );
            CREATE TABLE schedules (
                id TEXT PRIMARY KEY, name TEXT, rule TEXT, completed INTEGER, tombstone INTEGER
            );
            """)
        return (
            try BudgetDatabase(databaseURL: url, localNodeID: "account-freshness-tests"),
            url
        )
    }

    private var closeRequest: AccountLifecycleReviewRequest {
        AccountLifecycleReviewRequest(
            budgetID: "budget",
            accountID: "checking",
            requestedAction: .close(
                destinationAccountID: "destination",
                categoryID: "groceries"
            )
        )
    }

    private var testDay: AccountLifecycleDay {
        AccountLifecycleDay(isoDate: "2026-09-27", transactionDate: 20260927)
    }
}
