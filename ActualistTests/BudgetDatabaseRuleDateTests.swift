import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
@Suite("Budget database rule date values")
struct BudgetDatabaseRuleDateTests {
    private let support = LocalFirstActualStoreTests()

    @Test func previewsAndStoredTransactionConditionsUseTheRequestedDayConvention() async throws {
        let zones = [
            ActualDateOnly.utc,
            try #require(TimeZone(secondsFromGMT: 14 * 60 * 60)),
            try #require(TimeZone(secondsFromGMT: -12 * 60 * 60))
        ]
        let fixtureSQL = #"""
            CREATE TABLE rules (
                id TEXT PRIMARY KEY, stage TEXT, conditions TEXT, actions TEXT,
                conditions_op TEXT DEFAULT 'and', tombstone INTEGER DEFAULT 0
            );
            INSERT INTO rules VALUES (
                'date-rule', 'normal',
                '[{"op":"is","field":"date","value":"2026-07-03"}]',
                '[{"op":"set","field":"date","value":"2027-01-01"}]', 'and', 0
            );
            INSERT INTO rules VALUES (
                'same-day-rule', 'normal',
                '[{"op":"is","field":"date","value":"2027-01-01"}]',
                '[{"op":"set","field":"date","value":"2027-01-01"}]', 'and', 0
            );
            """#
        let url = try support.makeSQLiteFixture(extraSQL: fixtureSQL)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "rule-date-test")

        for timeZone in zones {
            let date = try #require(ActualDateOnly.date(from: "2026-07-03", timeZone: timeZone))
            let draft = TransactionDraft(
                accountID: "checking", date: date, amountMinorUnits: -12_345,
                payeeID: nil, payeeName: "", categoryID: nil, notes: nil,
                cleared: false, isTransfer: false
            )
            let preview = try await database.previewRules(for: draft, dateTimeZone: timeZone)
            let previewDate = try #require(preview.date)
            #expect(ActualDateOnly.dayID(from: previewDate, timeZone: timeZone) == "2027-01-01")

            let sameDayDraft = TransactionDraft(
                accountID: "checking",
                date: try #require(ActualDateOnly.date(from: "2027-01-01", timeZone: timeZone)),
                amountMinorUnits: -12_345,
                payeeID: nil,
                payeeName: "",
                categoryID: nil,
                notes: nil,
                cleared: false,
                isTransfer: false
            )
            let sameDayPreview = try await database.previewRules(for: sameDayDraft, dateTimeZone: timeZone)
            #expect(sameDayPreview.date == nil)

            let condition = RuleCondition(field: "date", operation: "is", value: .string("2026-07-03"))
            let matches = try await database.fetchMatchingTransactions(
                for: RuleDraft(stage: .normal, conditionsJoin: .and, conditions: [condition], actions: []),
                limit: 10,
                dateTimeZone: timeZone
            )
            #expect(matches.totalCount == 1)
            #expect(matches.transactions.first?.id == "txn")
        }

        let utcDate = try #require(ActualDateOnly.date(from: "2026-07-03", timeZone: ActualDateOnly.utc))
        let bankDraft = TransactionDraft(
            accountID: "checking", date: utcDate, amountMinorUnits: -12_345,
            payeeID: nil, payeeName: "", categoryID: nil, notes: nil,
            cleared: false, isTransfer: false
        )
        let bankPreview = try await database.previewRules(for: bankDraft, dateTimeZone: ActualDateOnly.utc)
        let candidate = BankSyncReconciliation.Candidate(
            financialID: "bank-rule-date",
            dayID: "20260703",
            amountMinorUnits: -12_345,
            payeeID: nil,
            payeeName: "Electric",
            notes: nil,
            categoryID: nil,
            cleared: false,
            importedPayee: nil
        )
        let projected = try #require(BankSyncReconciliation.applyingRulePreview(bankPreview, to: candidate))
        #expect(projected.dayID == "20270101")
    }

    @Test func balanceOfCutoffUsesTheCallerLogicalDayAcrossTimeZones() async throws {
        let url = try support.makeSQLiteFixture()
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions
                    (id, acct, date, amount, category, tombstone, parent_id, is_parent, sort_order)
                VALUES
                    ('balance-before', 'checking', 20260702, -5000, 'groceries', 0, NULL, 0, 1),
                    ('balance-same-day', 'checking', 20260703, -2000, 'groceries', 0, NULL, 0, 1),
                    ('balance-after', 'checking', 20260704, -3000, 'groceries', 0, NULL, 0, 1)
                """)
        }
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "balance-date-test")
        let zones = [
            ActualDateOnly.utc,
            try #require(TimeZone(secondsFromGMT: 14 * 60 * 60)),
            try #require(TimeZone(secondsFromGMT: -12 * 60 * 60))
        ]

        for timeZone in zones {
            let date = try #require(ActualDateOnly.date(from: "2026-07-03", timeZone: timeZone))
            let balances = try await database.prefetchBalanceOf(
                formulas: [#"=BALANCE_OF("Checking")"#],
                date: date,
                sortOrder: nil,
                excludingTransactionID: nil,
                dateTimeZone: timeZone
            )
            #expect(balances["Checking"] == -7_000)
        }
    }
}
