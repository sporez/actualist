import Foundation
import GRDB
import Testing
@testable import Actualist

/// Transfer schedules *into* a closing account reference it through its transfer
/// payee (directly, or through `payee_mapping` after a payee merge), not through
/// an account condition (main-to-dev audit F-3, remediation item 4.2).
@MainActor
struct AccountLifecycleTransferScheduleTests {
    private let support = LocalFirstActualStoreTests()

    @Test func transferScheduleIntoTheAccountIsListedForCloseAndEmptyDelete() async throws {
        let database = try makeDatabase(schedules: [
            schedule("rent", payeeCondition: #""xfer-checking""#),
        ])

        let close = try await database.accountLifecycleReview(request: closeRequest, localDay: testDay)
        #expect(close.activeScheduleReferences == [AccountScheduleReference(id: "rent", name: "rent")])

        let emptied = try makeDatabase(
            schedules: [schedule("rent", payeeCondition: #""xfer-checking""#)],
            extraSQL: "UPDATE transactions SET tombstone = 1;"
        )
        let delete = try await emptied.accountLifecycleReview(request: closeRequest, localDay: testDay)
        #expect(delete.resolvedAction == .deleteEmptyAccount)
        #expect(delete.activeScheduleReferences == [AccountScheduleReference(id: "rent", name: "rent")])
    }

    @Test func oneOfListsAndMergedPayeesResolveToTheTransferPayee() async throws {
        let database = try makeDatabase(
            schedules: [
                schedule("list", op: "oneOf", payeeCondition: #"["other","xfer-checking"]"#),
                schedule("merged", payeeCondition: #""merged-payee""#),
                schedule("unrelated", payeeCondition: #""xfer-savings""#),
            ],
            extraSQL: """
                INSERT INTO payee_mapping VALUES ('merged-payee', 'xfer-checking');
                INSERT INTO payee_mapping VALUES ('xfer-checking', 'xfer-checking');
                """
        )

        let review = try await database.accountLifecycleReview(request: closeRequest, localDay: testDay)

        #expect(review.activeScheduleReferences.map(\.id) == ["list", "merged"])
    }

    @Test func tombstonedSchedulesAndRulesAreExcluded() async throws {
        let database = try makeDatabase(
            schedules: [
                schedule("dead-schedule", payeeCondition: #""xfer-checking""#),
                schedule("dead-rule", payeeCondition: #""xfer-checking""#),
                schedule("live", payeeCondition: #""xfer-checking""#),
            ],
            extraSQL: """
                UPDATE schedules SET tombstone = 1 WHERE id = 'dead-schedule';
                UPDATE rules SET tombstone = 1 WHERE id = 'dead-rule-rule';
                """
        )

        let review = try await database.accountLifecycleReview(request: closeRequest, localDay: testDay)

        #expect(review.activeScheduleReferences.map(\.id) == ["live"])
    }

    @Test func digestChangesWhenAMergeRoutesAnotherPayeeToTheTransferPayee() async throws {
        let url = try makeFixtureURL(schedules: [schedule("merged", payeeCondition: #""merged-payee""#)])
        let database = try BudgetDatabase(databaseURL: url)
        let before = try await database.accountLifecycleReview(request: closeRequest, localDay: testDay)
        #expect(before.activeScheduleReferences.isEmpty)

        try await DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: "INSERT INTO payee_mapping VALUES ('merged-payee', 'xfer-checking')")
        }
        let after = try await database.accountLifecycleReview(request: closeRequest, localDay: testDay)

        #expect(after.activeScheduleReferences.map(\.id) == ["merged"])
        #expect(after.identity.scheduleDigest != before.identity.scheduleDigest)
    }

    private struct ScheduleSeed {
        let id: String
        let op: String
        let payeeCondition: String
    }

    private func schedule(_ id: String, op: String = "is", payeeCondition: String) -> ScheduleSeed {
        ScheduleSeed(id: id, op: op, payeeCondition: payeeCondition)
    }

    private func makeDatabase(schedules: [ScheduleSeed], extraSQL: String = "") throws -> BudgetDatabase {
        try BudgetDatabase(databaseURL: makeFixtureURL(schedules: schedules, extraSQL: extraSQL))
    }

    private func makeFixtureURL(schedules: [ScheduleSeed], extraSQL: String = "") throws -> URL {
        let inserts = schedules.map { seed in
            """
            INSERT INTO rules VALUES (
                '\(seed.id)-rule',
                '[{"field":"account","op":"is","value":"savings"},{"field":"payee","op":"\(seed.op)","value":\(seed.payeeCondition)}]',
                '[{"op":"link-schedule","value":"\(seed.id)"}]', 0
            );
            INSERT INTO schedules VALUES ('\(seed.id)', '\(seed.id)', '\(seed.id)-rule', 0, 0);
            """
        }.joined(separator: "\n")
        return try support.makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
            INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0, 2);
            CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER);
            INSERT INTO payees VALUES ('xfer-checking', '', 'checking', 0);
            INSERT INTO payees VALUES ('xfer-savings', '', 'savings', 0);
            CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT);
            CREATE TABLE rules (
                id TEXT PRIMARY KEY, conditions TEXT, actions TEXT, tombstone INTEGER
            );
            CREATE TABLE schedules (
                id TEXT PRIMARY KEY, name TEXT, rule TEXT, completed INTEGER, tombstone INTEGER
            );
            \(inserts)
            \(extraSQL)
            """)
    }

    private var closeRequest: AccountLifecycleReviewRequest {
        AccountLifecycleReviewRequest(
            budgetID: "budget",
            accountID: "checking",
            requestedAction: .close(destinationAccountID: nil, categoryID: nil)
        )
    }

    private var testDay: AccountLifecycleDay {
        AccountLifecycleDay(isoDate: "2026-09-27", transactionDate: 20260927)
    }
}
