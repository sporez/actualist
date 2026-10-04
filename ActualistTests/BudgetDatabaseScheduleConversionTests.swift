import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
@Suite("Budget database schedule conversion")
struct BudgetDatabaseScheduleConversionTests {
    private let support = LocalFirstActualStoreTests()

    @Test func futureConversionUsesCanonicalPayeeAndActualNullAmountAndCommitsWholeReplacement() async throws {
        let dates = Self.dates
        let fixture = try makeFixture(
            date: dates.tomorrow,
            amount: nil,
            payeeID: "alias-payee",
            payees: "INSERT INTO payees VALUES ('canonical-payee', 'Electric', NULL, 0);",
            mappings: "INSERT INTO payee_mapping VALUES ('canonical-payee', 'canonical-payee'); INSERT INTO payee_mapping VALUES ('alias-payee', 'canonical-payee');"
        )
        let review = try await review(fixture, today: dates.today)

        let receipt = try await fixture.database.convertFutureTransaction(review: review)

        #expect(receipt.appliedMessageCount > 0)
        #expect(receipt.sourceTransactionIDs == ["future"])
        #expect(try readInt("SELECT tombstone FROM transactions WHERE id = 'future'", fixture.url) == 1)
        #expect(try readInt("SELECT posts_transaction FROM schedules WHERE id = '\(review.identity.scheduleID)'", fixture.url) == 1)
        #expect(try readInt("SELECT COUNT(*) FROM actualist_outbox", fixture.url) == receipt.appliedMessageCount)
        let conditions = try decodeRuleJSON("SELECT conditions FROM rules WHERE id = '\(review.identity.ruleID)'", fixture.url)
        let fields = conditions.compactMap(\.objectValue)
        #expect(fields.map { $0["field"] } == [.string("date"), .string("amount"), .string("payee"), .string("account")])
        #expect(fields[1]["value"] == .number(0))
        #expect(fields[2]["value"] == .string("canonical-payee"))
        let actions = try decodeRuleJSON("SELECT actions FROM rules WHERE id = '\(review.identity.ruleID)'", fixture.url)
        #expect(actions.first?.objectValue?["op"] == .string("link-schedule"))
        #expect(try readInt("SELECT local_next_date FROM schedules_next_date WHERE id = '\(review.identity.nextDateID)'", fixture.url) == Self.packed(dates.tomorrow))
        await #expect(throws: ScheduleConversionError.reviewChanged) {
            _ = try await fixture.database.convertFutureTransaction(review: review)
        }
        #expect(try readInt("SELECT COUNT(*) FROM schedules", fixture.url) == 1)
    }

    @Test func validSplitPreservesChildOrderAndTombstonesEveryFamilyRow() async throws {
        let dates = Self.dates
        let fixture = try makeFixture(
            date: dates.tomorrow,
            amount: -900,
            extraTransactions: """
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, description, isChild, reconciled, cleared, sort_order, notes)
                VALUES ('split-parent', 'checking', \(Self.packed(dates.tomorrow)), -900, NULL, 0, NULL, 1, NULL, 0, 0, 1, 0, 'Parent note');
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, description, isChild, reconciled, cleared, sort_order, notes)
                VALUES ('child-first', 'checking', \(Self.packed(dates.tomorrow)), -400, 'groceries', 0, 'split-parent', 0, NULL, 1, 0, 1, -1, 'First');
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, description, isChild, reconciled, cleared, sort_order, notes)
                VALUES ('child-second', 'checking', \(Self.packed(dates.tomorrow)), -500, NULL, 0, 'split-parent', 0, NULL, 1, 0, 1, -2, NULL);
                """
        )
        let review = try await review(fixture, transactionID: "split-parent", today: dates.today)

        let receipt = try await fixture.database.convertFutureTransaction(review: review)

        #expect(receipt.sourceTransactionIDs == ["split-parent", "child-first", "child-second"])
        #expect(try readInt("SELECT COUNT(*) FROM transactions WHERE id IN ('split-parent','child-first','child-second') AND tombstone = 1", fixture.url) == 3)
        let actions = try decodeRuleJSON("SELECT actions FROM rules WHERE id = '\(review.identity.ruleID)'", fixture.url)
        let values = actions.compactMap(\.objectValue)
        #expect(values[0]["op"] == .string("link-schedule"))
        #expect(values[1]["options"]?.objectValue?["splitIndex"] == .number(0))
        #expect(values[2]["op"] == .string("set-split-amount"))
        #expect(values[2]["value"] == .number(-400))
        #expect(values[2]["options"]?.objectValue?["splitIndex"] == .number(1))
        #expect(values[3]["value"] == .string("groceries"))
        #expect(values[3]["options"]?.objectValue?["splitIndex"] == .number(1))
        #expect(values[4]["value"] == .string("First"))
        #expect(values[4]["options"]?.objectValue?["splitIndex"] == .number(1))
        #expect(values[5]["op"] == .string("set-split-amount"))
        #expect(values[5]["value"] == .number(-500))
        #expect(values[5]["options"]?.objectValue?["splitIndex"] == .number(2))
    }

    @Test func todayTransferAndReconciledFamiliesRefuseWithoutAnyWrites() async throws {
        let dates = Self.dates
        let today = try makeFixture(date: dates.today)
        let todayClock = await today.database.localClock
        await #expect(throws: ScheduleConversionError.transactionNotFuture) {
            _ = try await review(today, today: dates.today)
        }

        let transfer = try makeFixture(
            date: dates.tomorrow,
            payeeID: "transfer-payee",
            payees: "INSERT INTO payees VALUES ('transfer-payee', 'Transfer', 'credit', 0);",
            mappings: "INSERT INTO payee_mapping VALUES ('transfer-payee', 'transfer-payee');"
        )
        let transferClock = await transfer.database.localClock
        await #expect(throws: ScheduleConversionError.unsupportedSource("Transfer transactions cannot be converted to schedules.")) {
            _ = try await review(transfer, today: dates.today)
        }

        let reconciled = try makeFixture(date: dates.tomorrow, reconciled: true)
        let reconciledClock = await reconciled.database.localClock
        await #expect(throws: ScheduleConversionError.unsupportedSource("Reconciled transaction families cannot be converted.")) {
            _ = try await review(reconciled, today: dates.today)
        }
        try await expectNoConversionWrites(today, transactionIDs: ["future"], clock: todayClock)
        try await expectNoConversionWrites(transfer, transactionIDs: ["future"], clock: transferClock)
        try await expectNoConversionWrites(reconciled, transactionIDs: ["future"], clock: reconciledClock)
    }

    @Test func canonicalSelfMapAndAccountAreRevalidatedAtCommit() async throws {
        let dates = Self.dates
        let noSelfMap = try makeFixture(
            date: dates.tomorrow,
            payeeID: "canonical-payee",
            payees: "INSERT INTO payees VALUES ('canonical-payee', 'Electric', NULL, 0);",
            mappings: "INSERT INTO payee_mapping VALUES ('alias-payee', 'canonical-payee');"
        )
        await #expect(throws: ScheduleConversionError.unsupportedSource("The transaction payee has no live canonical self-mapping.")) {
            _ = try await review(noSelfMap, today: dates.today)
        }
        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", noSelfMap.url) == 0)

        let staleMap = try makeFixture(
            date: dates.tomorrow,
            payeeID: "canonical-payee",
            payees: "INSERT INTO payees VALUES ('canonical-payee', 'Electric', NULL, 0);",
            mappings: "INSERT INTO payee_mapping VALUES ('canonical-payee', 'canonical-payee');"
        )
        let staleMapReview = try await review(staleMap, today: dates.today)
        try execute(staleMap.url, sql: "UPDATE payee_mapping SET targetId = 'missing' WHERE id = 'canonical-payee'")
        await #expect(throws: ScheduleConversionError.unsupportedSource("The transaction payee has no live canonical self-mapping.")) {
            _ = try await staleMap.database.convertFutureTransaction(review: staleMapReview)
        }
        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", staleMap.url) == 0)

        let closedAccount = try makeFixture(date: dates.tomorrow)
        let accountReview = try await review(closedAccount, today: dates.today)
        try execute(closedAccount.url, sql: "UPDATE accounts SET closed = 1 WHERE id = 'checking'")
        await #expect(throws: ScheduleConversionError.unsupportedSource("The transaction account is unavailable or closed.")) {
            _ = try await closedAccount.database.convertFutureTransaction(review: accountReview)
        }
        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", closedAccount.url) == 0)
    }

    @Test func nullAndNonIdentityCanonicalMappingsAreRefused() async throws {
        let dates = Self.dates
        let nullMap = try makeFixture(
            date: dates.tomorrow,
            payeeID: "canonical-payee",
            payees: "INSERT INTO payees VALUES ('canonical-payee', 'Electric', NULL, 0);",
            mappings: "INSERT INTO payee_mapping VALUES ('canonical-payee', NULL);"
        )
        await #expect(throws: ScheduleConversionError.unsupportedSource("The transaction payee has no live canonical self-mapping.")) {
            _ = try await review(nullMap, today: dates.today)
        }

        let nonIdentity = try makeFixture(
            date: dates.tomorrow,
            payeeID: "alias-payee",
            payees: "INSERT INTO payees VALUES ('canonical-payee', 'Electric', NULL, 0); INSERT INTO payees VALUES ('alias-payee', 'Old Electric', NULL, 0);",
            mappings: "INSERT INTO payee_mapping VALUES ('alias-payee', 'canonical-payee'); INSERT INTO payee_mapping VALUES ('canonical-payee', 'alias-payee');"
        )
        await #expect(throws: ScheduleConversionError.unsupportedSource("The transaction payee has no live canonical self-mapping.")) {
            _ = try await review(nonIdentity, today: dates.today)
        }
        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", nullMap.url) == 0)
        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", nonIdentity.url) == 0)
    }

    @Test func transferLinkAndReconciledSplitChildAreRefused() async throws {
        let dates = Self.dates
        let linkedTransfer = try makeFixture(date: dates.tomorrow)
        let transferReview = try await review(linkedTransfer, today: dates.today)
        let transferClock = await linkedTransfer.database.localClock
        try execute(linkedTransfer.url, sql: "UPDATE transactions SET transferred_id = 'other-budget-row' WHERE id = 'future'")
        await #expect(throws: ScheduleConversionError.unsupportedSource("Transfer transactions cannot be converted to schedules.")) {
            _ = try await linkedTransfer.database.convertFutureTransaction(review: transferReview)
        }

        let reconciledChild = try makeFixture(
            date: dates.tomorrow,
            extraTransactions: """
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, description, isChild, reconciled, cleared, sort_order, notes)
                VALUES ('split-parent', 'checking', \(Self.packed(dates.tomorrow)), -900, NULL, 0, NULL, 1, NULL, 0, 0, 0, 0, NULL);
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, description, isChild, reconciled, cleared, sort_order, notes)
                VALUES ('reconciled-child', 'checking', \(Self.packed(dates.tomorrow)), -900, 'groceries', 0, 'split-parent', 0, NULL, 1, 0, 0, -1, NULL);
                """
        )
        let childReview = try await review(reconciledChild, transactionID: "split-parent", today: dates.today)
        let reconciledClock = await reconciledChild.database.localClock
        try execute(reconciledChild.url, sql: "UPDATE transactions SET reconciled = 1 WHERE id = 'reconciled-child'")
        await #expect(throws: ScheduleConversionError.unsupportedSource("Reconciled transaction families cannot be converted.")) {
            _ = try await reconciledChild.database.convertFutureTransaction(review: childReview)
        }
        try await expectNoConversionWrites(linkedTransfer, transactionIDs: ["future"], clock: transferClock)
        try await expectNoConversionWrites(
            reconciledChild,
            transactionIDs: ["split-parent", "reconciled-child"],
            clock: reconciledClock
        )
    }

    @Test func identityCollisionDoesNotMintReplacementOrCreateAnything() async throws {
        let dates = Self.dates
        let fixture = try makeFixture(date: dates.tomorrow)
        let review = try await review(fixture, today: dates.today)
        try execute(fixture.url, sql: "INSERT INTO schedules (id, rule, tombstone) VALUES ('converted-schedule', 'other-rule', 0)")

        await #expect(throws: ScheduleConversionError.identityConflict) {
            _ = try await fixture.database.convertFutureTransaction(review: review)
        }

        #expect(try readInt("SELECT COUNT(*) FROM schedules WHERE id = 'converted-schedule'", fixture.url) == 1)
        #expect(try readInt("SELECT COUNT(*) FROM rules WHERE id = 'converted-rule'", fixture.url) == 0)
        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", fixture.url) == 0)
        #expect(try readInt("SELECT tombstone FROM transactions WHERE id = 'future'", fixture.url) == 0)
    }

    @Test func staleFingerprintAndMidnightBoundaryRejectBeforeMutation() async throws {
        let dates = Self.dates
        let changed = try makeFixture(date: dates.tomorrow)
        let changedReview = try await review(changed, today: dates.today)
        try execute(changed.url, sql: "UPDATE transactions SET amount = -999 WHERE id = 'future'")
        await #expect(throws: ScheduleConversionError.reviewChanged) {
            _ = try await changed.database.convertFutureTransaction(review: changedReview)
        }
        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", changed.url) == 0)

        let crossedDay = try makeFixture(date: dates.today)
        let yesterday = Self.day(before: dates.today)
        let staleDayReview = try await review(crossedDay, today: yesterday)
        await #expect(throws: ScheduleConversionError.reviewChanged) {
            _ = try await crossedDay.database.convertFutureTransaction(review: staleDayReview)
        }
        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", crossedDay.url) == 0)
    }

    @Test func failedFamilyTombstoneRollsBackScheduleRuleClockAndOutbox() async throws {
        let dates = Self.dates
        let fixture = try makeFixture(date: dates.tomorrow)
        let review = try await review(fixture, today: dates.today)
        try execute(fixture.url, sql: """
            CREATE TRIGGER reject_conversion_tombstone
            BEFORE UPDATE OF tombstone ON transactions WHEN NEW.id = 'future'
            BEGIN SELECT RAISE(ABORT, 'conversion rejected'); END;
            """)

        await #expect(throws: LocalFirstError.self) {
            _ = try await fixture.database.convertFutureTransaction(review: review)
        }

        #expect(try readInt("SELECT COUNT(*) FROM schedules", fixture.url) == 0)
        #expect(try readInt("SELECT COUNT(*) FROM rules", fixture.url) == 0)
        #expect(try readInt("SELECT COUNT(*) FROM schedules_next_date", fixture.url) == 0)
        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", fixture.url) == 0)
        #expect(try readInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='actualist_outbox'", fixture.url) == 0)
        #expect(try readInt("SELECT tombstone FROM transactions WHERE id = 'future'", fixture.url) == 0)
    }

    private struct Fixture {
        let url: URL
        let database: BudgetDatabase
    }

    private func makeFixture(
        date: String,
        amount: Int? = -1200,
        payeeID: String? = nil,
        reconciled: Bool = false,
        payees: String = "",
        mappings: String = "",
        extraTransactions: String = ""
    ) throws -> Fixture {
        let sql = """
            ALTER TABLE transactions ADD COLUMN description TEXT;
            ALTER TABLE transactions ADD COLUMN isChild INTEGER DEFAULT 0;
            ALTER TABLE transactions ADD COLUMN cleared INTEGER DEFAULT 0;
            ALTER TABLE transactions ADD COLUMN notes TEXT;
            ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
            ALTER TABLE transactions ADD COLUMN reconciled INTEGER DEFAULT 0;
            ALTER TABLE transactions ADD COLUMN sort_order REAL;
            CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER DEFAULT 0);
            CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT);
            CREATE TABLE rules (id TEXT PRIMARY KEY, stage TEXT, conditions TEXT, actions TEXT, conditions_op TEXT DEFAULT 'and', tombstone INTEGER DEFAULT 0);
            CREATE TABLE schedules (id TEXT PRIMARY KEY, rule TEXT, name TEXT, active INTEGER DEFAULT 0, completed INTEGER DEFAULT 0, posts_transaction INTEGER DEFAULT 0, custom_upcoming_length TEXT, sort_order REAL, tombstone INTEGER DEFAULT 0);
            CREATE TABLE schedules_next_date (id TEXT PRIMARY KEY, schedule_id TEXT, local_next_date INTEGER, local_next_date_ts INTEGER, base_next_date INTEGER, base_next_date_ts INTEGER, tombstone INTEGER DEFAULT 0);
            UPDATE transactions SET id = 'future', date = \(Self.packed(date)), amount = \(amount.map { String($0) } ?? "NULL"), description = \(payeeID.map { "'\($0)'" } ?? "NULL"), reconciled = \(reconciled ? 1 : 0), cleared = 1, notes = 'Memo' WHERE id = 'txn';
            \(payees)
            \(mappings)
            \(extraTransactions)
            """
        let url = try support.makeSQLiteFixture(extraSQL: sql)
        return Fixture(url: url, database: try BudgetDatabase(databaseURL: url, localNodeID: "schedule-conversion-test"))
    }

    private func review(
        _ fixture: Fixture,
        transactionID: String = "future",
        today: String
    ) async throws -> ScheduleConversionReview {
        try await fixture.database.scheduleConversionReview(
            context: ScheduleMutationSessionContext(budgetID: "budget", generation: 1),
            transactionID: transactionID,
            asOfDayID: today,
            identity: ScheduleCreateIdentity(
                scheduleID: "converted-schedule",
                ruleID: "converted-rule",
                nextDateID: "converted-next"
            )
        )
    }

    private func decodeRuleJSON(_ sql: String, _ url: URL) throws -> [RuleJSONValue] {
        let json = try #require(try readString(sql, url))
        return try JSONDecoder().decode([RuleJSONValue].self, from: Data(json.utf8))
    }

    private func execute(_ url: URL, sql: String) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in try db.execute(sql: sql) }
    }

    private func readString(_ sql: String, _ url: URL) throws -> String? {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.readSync { db in try String.fetchOne(db, sql: sql) }
    }

    private func readInt(_ sql: String, _ url: URL) throws -> Int {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.readSync { db in try Int.fetchOne(db, sql: sql) ?? -1 }
    }

    private func expectNoConversionWrites(
        _ fixture: Fixture,
        transactionIDs: [String],
        clock: HybridLogicalClock?
    ) async throws {
        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", fixture.url) == 0)
        #expect(try readInt("SELECT COUNT(*) FROM schedules", fixture.url) == 0)
        #expect(try readInt("SELECT COUNT(*) FROM rules", fixture.url) == 0)
        #expect(try readInt("SELECT COUNT(*) FROM schedules_next_date", fixture.url) == 0)
        #expect(try readInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='actualist_outbox'", fixture.url) == 0)
        for transactionID in transactionIDs {
            #expect(try readInt("SELECT tombstone FROM transactions WHERE id = '\(transactionID)'", fixture.url) == 0)
        }
        #expect(await fixture.database.localClock == clock)
    }

    private static var dates: (today: String, tomorrow: String) {
        let calendar = TestLocalDay.calendar
        let today = TestLocalDay.today()
        let date = ActualScheduleRecurrence.date(from: today, calendar: calendar)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date)!
        return (today, ActualScheduleRecurrence.dayID(from: tomorrow, calendar: calendar))
    }

    private static func packed(_ dayID: String) -> Int {
        Int(dayID.replacingOccurrences(of: "-", with: ""))!
    }

    private static func day(before dayID: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let date = ActualScheduleRecurrence.date(from: dayID, calendar: calendar)!
        let previous = calendar.date(byAdding: .day, value: -1, to: date)!
        return ActualScheduleRecurrence.dayID(from: previous, calendar: calendar)
    }
}

private extension RuleJSONValue {
    var objectValue: [String: RuleJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}
