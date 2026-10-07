import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
@Suite("Budget database schedule posting")
struct BudgetDatabaseSchedulePostingTests {
    private let support = LocalFirstActualStoreTests()

    @Test func scheduledPostPersistsScheduleIdentityOutboxAndHistoryInOneCommit() async throws {
        let fixture = try makeFixture()
        let review = try await fixture.database.scheduleMutationReview(budgetID: "budget", scheduleID: "rent")

        let receipt = try await fixture.database.postScheduleOccurrence(
            review: review,
            draft: draft(),
            transactionID: "posted",
            postedDayID: Self.today,
            asOf: Self.today,
            now: Self.noon
        )

        #expect(receipt.transactionID == "posted")
        #expect(receipt.appliedMessageCount > 0)
        #expect(try readInt("SELECT COUNT(*) FROM transactions WHERE id = 'posted'", fixture.url) == 1)
        #expect(try readInt("SELECT COUNT(*) FROM transactions WHERE id = 'posted' AND schedule = 'rent'", fixture.url) == 1)
        #expect(try readInt("SELECT COUNT(*) FROM actualist_outbox", fixture.url) == receipt.appliedMessageCount)
        #expect(try await fixture.database.fetchSchedules(budgetID: "budget", today: Self.today)
            .detail(id: "rent")?.status == .paid)

        await #expect(throws: SchedulePostingRefusal.self) {
            try await fixture.database.postScheduleOccurrence(
                review: review,
                draft: draft(),
                transactionID: "duplicate",
                postedDayID: Self.today,
                asOf: Self.today,
                now: Self.noon
            )
        }
        #expect(try readInt("SELECT COUNT(*) FROM transactions WHERE schedule = 'rent'", fixture.url) == 1)
    }

    @Test func alreadyPaidAndStaleReviewedRuleAreRejectedWithoutWrites() async throws {
        let paid = try makeFixture(extraSQL: """
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, schedule)
            VALUES ('peer-posted', 'checking', \(Self.packedToday), -10000, NULL, 0, 'rent');
            """)
        let paidReview = try await paid.database.scheduleMutationReview(budgetID: "budget", scheduleID: "rent")
        let before = try readInt("SELECT COUNT(*) FROM messages_crdt", paid.url)
        await #expect(throws: SchedulePostingRefusal.self) {
            try await paid.database.postScheduleOccurrence(
                review: paidReview, draft: draft(), transactionID: "duplicate",
                postedDayID: Self.today, asOf: Self.today, now: Self.noon
            )
        }
        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", paid.url) == before)
        #expect(try readInt("SELECT COUNT(*) FROM transactions WHERE id = 'duplicate'", paid.url) == 0)

        let stale = try makeFixture()
        let review = try await stale.database.scheduleMutationReview(budgetID: "budget", scheduleID: "rent")
        try execute(stale.url, sql: "UPDATE rules SET actions = '[{\"op\":\"link-schedule\",\"value\":\"rent\",\"remote\":true}]' WHERE id = 'rent-rule'")
        let staleBefore = try readInt("SELECT COUNT(*) FROM messages_crdt", stale.url)
        await #expect(throws: ScheduleMutationCommandError.self) {
            try await stale.database.postScheduleOccurrence(
                review: review, draft: draft(), transactionID: "stale",
                postedDayID: Self.today, asOf: Self.today, now: Self.noon
            )
        }
        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", stale.url) == staleBefore)
    }

    @Test func draftDateMismatchThrowsTypedRefusalWithoutInternalText() async throws {
        let fixture = try makeFixture()
        let review = try await fixture.database.scheduleMutationReview(budgetID: "budget", scheduleID: "rent")
        var mismatched = draft()
        mismatched = TransactionDraft(
            accountID: mismatched.accountID,
            date: Calendar.current.date(byAdding: .day, value: -1, to: Self.date)!,
            amountMinorUnits: mismatched.amountMinorUnits,
            payeeID: nil, payeeName: "", categoryID: nil, notes: nil,
            cleared: false, isTransfer: false, scheduleID: "rent"
        )
        let before = try readInt("SELECT COUNT(*) FROM messages_crdt", fixture.url)

        await #expect(throws: SchedulePostingRefusal.draftMismatch) {
            try await fixture.database.postScheduleOccurrence(
                review: review, draft: mismatched, transactionID: "mismatch",
                postedDayID: Self.today, asOf: Self.today, now: Self.noon
            )
        }

        #expect(SchedulePostingRefusal.draftMismatch.errorDescription?.contains("local-first write") == false)
        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", fixture.url) == before)
    }

    /// A rule that points at a deleted category is a liveness failure the user can
    /// fix, not a budget-layout gap (main-to-dev audit F-3).
    @Test func ruleSettingTombstonedCategoryRefusesAsReferencedRowUnavailable() async throws {
        let fixture = try makeFixture(extraSQL: """
            INSERT INTO categories VALUES ('gone', 'Gone', 'group', 0, 0, 1, 2);
            INSERT INTO rules VALUES (
                'gone-category-rule', 'normal',
                '[{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":-10000}]',
                '[{"op":"set","field":"category","value":"gone","type":"id"}]', 'and', 0
            );
            """)
        let review = try await fixture.database.scheduleMutationReview(budgetID: "budget", scheduleID: "rent")
        let messagesBefore = try readInt("SELECT COUNT(*) FROM messages_crdt", fixture.url)

        await #expect(throws: SchedulePostingRefusal.referencedRowUnavailable) {
            try await fixture.database.postScheduleOccurrence(
                review: review, draft: draft(), transactionID: "gone-category",
                postedDayID: Self.today, asOf: Self.today, now: Self.noon
            )
        }

        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", fixture.url) == messagesBefore)
        #expect(try readInt("SELECT COUNT(*) FROM transactions WHERE id = 'gone-category'", fixture.url) == 0)
    }

    @Test func transferIntoClosedAccountRefusesAsReferencedRowUnavailable() async throws {
        let fixture = try makeFixture(extraSQL: "UPDATE accounts SET closed = 1 WHERE id = 'credit';")
        let review = try await fixture.database.scheduleMutationReview(budgetID: "budget", scheduleID: "rent")
        let transfer = TransactionDraft(
            accountID: "checking", date: Self.date, amountMinorUnits: -10_000,
            payeeID: "xfer-credit", payeeName: "", categoryID: nil, notes: nil,
            cleared: false, isTransfer: true, scheduleID: "rent"
        )

        await #expect(throws: SchedulePostingRefusal.referencedRowUnavailable) {
            try await fixture.database.postScheduleOccurrence(
                review: review, draft: transfer, transactionID: "closed-transfer",
                postedDayID: Self.today, asOf: Self.today, now: Self.noon
            )
        }
        #expect(try readInt("SELECT COUNT(*) FROM transactions WHERE id = 'closed-transfer'", fixture.url) == 0)
    }

    @Test func referencedRowRefusalCopyIsActionableAndHidesInternalText() {
        let message = SchedulePostingRefusal.referencedRowUnavailable.errorDescription ?? ""
        #expect(message.contains("rule") && message.contains("account"))
        #expect(!message.contains("local-first write"))
    }

    @Test func concurrentSameClientPostsCommitAtMostOneOccurrence() async throws {
        let fixture = try makeFixture()
        let review = try await fixture.database.scheduleMutationReview(budgetID: "budget", scheduleID: "rent")
        let first = Task {
            try await fixture.database.postScheduleOccurrence(
                review: review, draft: draft(), transactionID: "first",
                postedDayID: Self.today, asOf: Self.today, now: Self.noon
            )
        }
        let second = Task {
            try await fixture.database.postScheduleOccurrence(
                review: review, draft: draft(), transactionID: "second",
                postedDayID: Self.today, asOf: Self.today, now: Self.noon
            )
        }
        let firstSucceeded = (try? await first.value) != nil
        let secondSucceeded = (try? await second.value) != nil

        #expect(firstSucceeded != secondSucceeded)
        #expect(try readInt("SELECT COUNT(*) FROM transactions WHERE schedule = 'rent'", fixture.url) == 1)
    }

    @Test func commitUsesLatestMatchingRuleAndKeepsOccurrenceSeparateFromRuleChangedMonth() async throws {
        let shiftedDate = Self.nextMonthDay
        let fixture = try makeFixture(extraSQL: """
            INSERT INTO categories VALUES ('utilities', 'Utilities', 'group', 0, 0, 0, 2);
            INSERT INTO rules VALUES (
                'date-shift-rule', 'normal',
                '[{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":-10000}]',
                '[{"op":"set","field":"date","value":"\(shiftedDate)"}]', 'and', 0
            );
            INSERT INTO rules VALUES (
                'mutable-category-rule', 'normal',
                '[{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":-10000}]',
                '[{"op":"set","field":"category","value":"groceries","type":"id"}]', 'and', 0
            );
            """)
        let review = try await fixture.database.scheduleMutationReview(budgetID: "budget", scheduleID: "rent")
        let baseDraft = draft()
        let oldPreview = try await fixture.database.previewRules(for: baseDraft)
        #expect(oldPreview.categoryID == "groceries")
        #expect(oldPreview.date.map(Self.dayID) == shiftedDate)
        try execute(
            fixture.url,
            sql: "UPDATE rules SET actions = '[{\"op\":\"set\",\"field\":\"category\",\"value\":\"utilities\",\"type\":\"id\"}]' WHERE id = 'mutable-category-rule'"
        )

        let receipt = try await fixture.database.postScheduleOccurrence(
            review: review, draft: baseDraft, transactionID: "rule-changed",
            postedDayID: Self.today, asOf: Self.today, now: Self.noon
        )

        #expect(receipt.occurrenceDayID == Self.today)
        #expect(receipt.postedDayID == shiftedDate)
        #expect(receipt.affectedMonthIDs == [String(shiftedDate.prefix(7))])
        let packedShiftedDate = Int(shiftedDate.replacingOccurrences(of: "-", with: ""))!
        #expect(try readInt("SELECT COUNT(*) FROM transactions WHERE id = 'rule-changed' AND category = 'utilities' AND date = \(packedShiftedDate)", fixture.url) == 1)
        // Actual's schedule status query uses a lower date bound, not an
        // occurrence-date upper bound; a rule-shifted later transaction pays it.
        #expect(try await fixture.database.fetchSchedules(budgetID: "budget", today: Self.today)
            .detail(id: "rent")?.status == .paid)
    }

    @Test func postTodayIsRejectedWhenUpcomingExactOccurrenceCannotBeMatched() async throws {
        let occurrence = Self.dayID(afterToday: 3)
        let fixture = try makeFixture(extraSQL: """
            UPDATE schedules_next_date
            SET local_next_date = \(Self.packedDay(occurrence)), base_next_date = \(Self.packedDay(occurrence))
            WHERE schedule_id = 'rent';
            """)
        let review = try await fixture.database.scheduleMutationReview(budgetID: "budget", scheduleID: "rent")
        let clockBefore = await fixture.database.localClock
        let transactionsBefore = try readInt("SELECT COUNT(*) FROM transactions", fixture.url)
        let messagesBefore = try readInt("SELECT COUNT(*) FROM messages_crdt", fixture.url)
        let outboxBefore = try readOptionalTableCount("actualist_outbox", fixture.url)
        let historyBefore = try readOptionalTableCount("actualist_action_log", fixture.url)

        for _ in 0..<2 {
            let message = try await rejectionMessage {
                try await fixture.database.postScheduleOccurrence(
                    review: review, draft: draft(), transactionID: "too-early",
                    postedDayID: Self.today, asOf: Self.today, now: Self.noon
                )
            }
            #expect(message.contains("before Actual's payment match window"))
            #expect(message.contains("Actual will not mark it as paid"))
            #expect(message.contains(occurrence))
        }

        #expect(try readInt("SELECT COUNT(*) FROM transactions", fixture.url) == transactionsBefore)
        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", fixture.url) == messagesBefore)
        #expect(try readOptionalTableCount("actualist_outbox", fixture.url) == outboxBefore)
        #expect(try readOptionalTableCount("actualist_action_log", fixture.url) == historyBefore)
        #expect(await fixture.database.localClock == clockBefore)
        #expect(try await fixture.database.fetchSchedules(budgetID: "budget", today: Self.today)
            .detail(id: "rent")?.status == .upcoming)
    }

    @Test func dateRuleBeforeApproximateMatchWindowIsRejectedWithoutCommit() async throws {
        let occurrence = Self.dayID(afterToday: 3)
        let earlierDate = Self.dayID(afterToday: -1)
        let fixture = try makeFixture(extraSQL: Self.approximateDateSQL(occurrence: occurrence) + """
            INSERT INTO rules VALUES (
                'move-date-earlier', 'normal',
                '[{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":-10000}]',
                '[{"op":"set","field":"date","value":"\(earlierDate)"}]', 'and', 0
            );
            """)
        let review = try await fixture.database.scheduleMutationReview(budgetID: "budget", scheduleID: "rent")
        let clockBefore = await fixture.database.localClock
        let messagesBefore = try readInt("SELECT COUNT(*) FROM messages_crdt", fixture.url)
        let transactionCountBefore = try readInt("SELECT COUNT(*) FROM transactions", fixture.url)
        let outboxBefore = try readOptionalTableCount("actualist_outbox", fixture.url)
        let historyBefore = try readOptionalTableCount("actualist_action_log", fixture.url)

        for _ in 0..<2 {
            let message = try await rejectionMessage {
                try await fixture.database.postScheduleOccurrence(
                    review: review, draft: draft(), transactionID: "rule-too-early",
                    postedDayID: Self.today, asOf: Self.today, now: Self.noon
                )
            }
            #expect(message.contains("before Actual's payment match window"))
            #expect(message.contains("Actual will not mark it as paid"))
            #expect(message.contains(Self.dayID(afterToday: 1)))
        }
        #expect(try readInt("SELECT COUNT(*) FROM transactions", fixture.url) == transactionCountBefore)
        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", fixture.url) == messagesBefore)
        #expect(try readOptionalTableCount("actualist_outbox", fixture.url) == outboxBefore)
        #expect(try readOptionalTableCount("actualist_action_log", fixture.url) == historyBefore)
        #expect(await fixture.database.localClock == clockBefore)
    }

    @Test func approximateManualPostingAtTwoDayLookbackBoundaryIsAccepted() async throws {
        let occurrence = Self.dayID(afterToday: 2)
        let fixture = try makeFixture(extraSQL: Self.approximateDateSQL(occurrence: occurrence))
        let review = try await fixture.database.scheduleMutationReview(budgetID: "budget", scheduleID: "rent")

        let receipt = try await fixture.database.postScheduleOccurrence(
            review: review, draft: draft(), transactionID: "approximate-boundary",
            postedDayID: Self.today, asOf: Self.today, now: Self.noon
        )

        #expect(receipt.occurrenceDayID == occurrence)
        #expect(receipt.postedDayID == Self.today)
        #expect(try await fixture.database.fetchSchedules(budgetID: "budget", today: Self.today)
            .detail(id: "rent")?.status == .paid)

        let messagesAfterPost = try readInt("SELECT COUNT(*) FROM messages_crdt", fixture.url)
        await #expect(throws: SchedulePostingRefusal.self) {
            try await fixture.database.postScheduleOccurrence(
                review: review, draft: draft(), transactionID: "approximate-repeat",
                postedDayID: Self.today, asOf: Self.today, now: Self.noon
            )
        }
        #expect(try readInt("SELECT COUNT(*) FROM transactions WHERE schedule = 'rent'", fixture.url) == 1)
        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", fixture.url) == messagesAfterPost)
    }

    @Test func splitGraphAndTransferScheduleCoverageArePreserved() async throws {
        let splitFixture = try makeFixture(extraSQL: """
            INSERT INTO categories VALUES ('utilities', 'Utilities', 'group', 0, 0, 0, 2);
            """)
        let splitReview = try await splitFixture.database.scheduleMutationReview(budgetID: "budget", scheduleID: "rent")
        let split = TransactionDraft(
            accountID: "checking", date: Self.date, amountMinorUnits: -10_000,
            payeeID: nil, payeeName: "", categoryID: nil, notes: "memo",
            cleared: false, isTransfer: false, isParent: true,
            splits: [TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: nil, amountMinorUnits: -4_000),
                     TransactionSplitDraft(id: nil, categoryID: "utilities", categoryName: nil, amountMinorUnits: -6_000)],
            scheduleID: "rent"
        )
        _ = try await splitFixture.database.postScheduleOccurrence(
            review: splitReview, draft: split, transactionID: "split-parent",
            postedDayID: Self.today, asOf: Self.today, now: Self.noon
        )
        #expect(try readInt("SELECT COUNT(*) FROM transactions WHERE id = 'split-parent' AND schedule = 'rent'", splitFixture.url) == 1)
        #expect(try readInt("SELECT COUNT(*) FROM transactions WHERE parent_id = 'split-parent' AND schedule IS NOT NULL", splitFixture.url) == 0)

        let transferFixture = try makeFixture()
        let transferReview = try await transferFixture.database.scheduleMutationReview(budgetID: "budget", scheduleID: "rent")
        let transfer = TransactionDraft(
            accountID: "checking", date: Self.date, amountMinorUnits: -10_000,
            payeeID: "xfer-credit", payeeName: "Credit Card", categoryID: nil, notes: nil,
            cleared: false, isTransfer: true, scheduleID: "rent"
        )
        _ = try await transferFixture.database.postScheduleOccurrence(
            review: transferReview, draft: transfer, transactionID: "transfer-source",
            postedDayID: Self.today, asOf: Self.today, now: Self.noon
        )
        #expect(try readInt("SELECT COUNT(*) FROM transactions WHERE id = 'transfer-source' AND schedule = 'rent'", transferFixture.url) == 1)
        #expect(try readInt("SELECT COUNT(*) FROM transactions WHERE transferred_id = 'transfer-source' AND schedule = 'rent'", transferFixture.url) == 1)

        let reassignedTransferFixture = try makeFixture(extraSQL: """
            INSERT INTO rules VALUES (
                'unowned-counterpart-relink', 'post',
                '[{"op":"is","field":"account","value":"credit"},{"op":"is","field":"amount","value":10000},{"op":"is","field":"date","value":"\(Self.today)"}]',
                '[{"op":"link-schedule","value":"counterpart-schedule"}]', 'and', 0
            );
            """)
        // Another live schedule's rule is skipped for an attached transaction.
        // An unowned post-stage rule instead relinks after rent's forced rule.
        let reassignedReview = try await reassignedTransferFixture.database.scheduleMutationReview(budgetID: "budget", scheduleID: "rent")
        let transferMessagesBefore = try readInt("SELECT COUNT(*) FROM messages_crdt", reassignedTransferFixture.url)
        let transferRowsBefore = try readInt("SELECT COUNT(*) FROM transactions", reassignedTransferFixture.url)
        let transferOutboxBefore = try readOptionalTableCount("actualist_outbox", reassignedTransferFixture.url)
        let transferHistoryBefore = try readOptionalTableCount("actualist_action_log", reassignedTransferFixture.url)
        let transferClockBefore = await reassignedTransferFixture.database.localClock
        let errorMessage = try await rejectionMessage {
            try await reassignedTransferFixture.database.postScheduleOccurrence(
                review: reassignedReview, draft: transfer, transactionID: "reassigned-transfer",
                postedDayID: Self.today, asOf: Self.today, now: Self.noon
            )
        }
        #expect(errorMessage.contains("changed the transaction's schedule link"))
        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", reassignedTransferFixture.url) == transferMessagesBefore)
        #expect(try readInt("SELECT COUNT(*) FROM transactions WHERE id = 'reassigned-transfer'", reassignedTransferFixture.url) == 0)
        #expect(try readInt("SELECT COUNT(*) FROM transactions", reassignedTransferFixture.url) == transferRowsBefore)
        #expect(try readOptionalTableCount("actualist_outbox", reassignedTransferFixture.url) == transferOutboxBefore)
        #expect(try readOptionalTableCount("actualist_action_log", reassignedTransferFixture.url) == transferHistoryBefore)
        #expect(await reassignedTransferFixture.database.localClock == transferClockBefore)
    }

    @Test func graphFailureRollsBackTransactionMessagesOutboxAndHistory() async throws {
        let fixture = try makeFixture()
        let review = try await fixture.database.scheduleMutationReview(budgetID: "budget", scheduleID: "rent")
        try execute(fixture.url, sql: """
            CREATE TRIGGER reject_schedule_post BEFORE INSERT ON transactions
            WHEN NEW.id = 'posted'
            BEGIN SELECT RAISE(ABORT, 'post rejected'); END;
            """)
        let before = try readInt("SELECT COUNT(*) FROM messages_crdt", fixture.url)

        await #expect(throws: LocalFirstError.self) {
            try await fixture.database.postScheduleOccurrence(
                review: review, draft: draft(), transactionID: "posted",
                postedDayID: Self.today, asOf: Self.today, now: Self.noon
            )
        }

        #expect(try readInt("SELECT COUNT(*) FROM messages_crdt", fixture.url) == before)
        #expect(try readInt("SELECT COUNT(*) FROM transactions WHERE id = 'posted'", fixture.url) == 0)
        #expect(try readInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'actualist_outbox'", fixture.url) == 0)
    }

    private struct Fixture {
        let url: URL
        let database: BudgetDatabase
    }

    private func makeFixture(extraSQL: String = "") throws -> Fixture {
        let scheduleSQL = """
            ALTER TABLE transactions ADD COLUMN schedule TEXT;
            ALTER TABLE transactions ADD COLUMN description TEXT;
            ALTER TABLE transactions ADD COLUMN notes TEXT;
            ALTER TABLE transactions ADD COLUMN cleared INTEGER;
            ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
            ALTER TABLE transactions ADD COLUMN isChild INTEGER;
            INSERT INTO accounts VALUES ('credit', 'Credit Card', 0, 0, 0, 2);
            CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER);
            INSERT INTO payees VALUES ('xfer-credit', '', 'credit', 0);
            INSERT INTO payees VALUES ('xfer-checking', '', 'checking', 0);
            CREATE TABLE rules (
                id TEXT PRIMARY KEY, stage TEXT, conditions TEXT, actions TEXT,
                conditions_op TEXT DEFAULT 'and', tombstone INTEGER DEFAULT 0
            );
            CREATE TABLE schedules (
                id TEXT PRIMARY KEY, rule TEXT, name TEXT, completed INTEGER DEFAULT 0,
                posts_transaction INTEGER DEFAULT 0, custom_upcoming_length TEXT,
                sort_order REAL, tombstone INTEGER DEFAULT 0
            );
            CREATE TABLE schedules_next_date (
                id TEXT PRIMARY KEY, schedule_id TEXT, local_next_date INTEGER,
                local_next_date_ts INTEGER, base_next_date INTEGER, base_next_date_ts INTEGER,
                tombstone INTEGER DEFAULT 0
            );
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('upcomingScheduledTransactionLength', '7');
            INSERT INTO rules VALUES (
                'rent-rule', 'normal',
                '[{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":-10000},{"op":"is","field":"date","value":"\(Self.today)"}]',
                '[{"op":"link-schedule","value":"rent"}]', 'and', 0
            );
            INSERT INTO schedules VALUES ('rent', 'rent-rule', 'Rent', 0, 0, NULL, 1, 0);
            INSERT INTO schedules_next_date VALUES ('rent-next', 'rent', \(Self.packedToday), 100, \(Self.packedToday), 100, 0);
            \(extraSQL)
            """
        let url = try support.makeSQLiteFixture(extraSQL: scheduleSQL)
        return Fixture(url: url, database: try BudgetDatabase(databaseURL: url, localNodeID: "schedule-post-node"))
    }

    private func draft() -> TransactionDraft {
        TransactionDraft(
            accountID: "checking", date: Self.date, amountMinorUnits: -10_000,
            payeeID: nil, payeeName: "", categoryID: nil, notes: nil,
            cleared: false, isTransfer: false, scheduleID: "rent"
        )
    }

    private static var date: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let parts = today.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }

    private static var packedToday: Int { Int(today.replacingOccurrences(of: "-", with: ""))! }
    private static var today: String { TestLocalDay.today() }
    private static var noon: Date { date }

    private static func dayID(_ date: Date) -> String {
        TestLocalDay.dayID(date)
    }

    private static var nextMonthDay: String {
        let calendar = Calendar.actualScheduleGregorian
        let date = ActualScheduleRecurrence.date(from: today, calendar: calendar)!
        let next = calendar.date(byAdding: .month, value: 1, to: date)!
        return ActualScheduleRecurrence.dayID(from: next, calendar: calendar)
    }

    private static func dayID(afterToday offset: Int) -> String {
        let calendar = Calendar.actualScheduleGregorian
        let date = ActualScheduleRecurrence.date(from: today, calendar: calendar)!
        let shifted = calendar.date(byAdding: .day, value: offset, to: date)!
        return ActualScheduleRecurrence.dayID(from: shifted, calendar: calendar)
    }

    private static func packedDay(_ dayID: String) -> Int {
        Int(dayID.replacingOccurrences(of: "-", with: ""))!
    }

    private static func approximateDateSQL(occurrence: String) -> String {
        """
        UPDATE rules SET conditions = '[{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":-10000},{"op":"isapprox","field":"date","value":"\(occurrence)"}]'
        WHERE id = 'rent-rule';
        UPDATE schedules_next_date
        SET local_next_date = \(packedDay(occurrence)), base_next_date = \(packedDay(occurrence))
        WHERE schedule_id = 'rent';
        """
    }

    private func execute(_ url: URL, sql: String) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in try db.execute(sql: sql) }
    }

    private func readInt(_ sql: String, _ url: URL) throws -> Int {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.readSync { db in try Int.fetchOne(db, sql: sql) ?? -1 }
    }

    private func readOptionalTableCount(_ table: String, _ url: URL) throws -> Int? {
        guard try readInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(table)'", url
        ) > 0 else { return nil }
        return try readInt("SELECT COUNT(*) FROM \(table)", url)
    }

    private func rejectionMessage(
        operation: () async throws -> SchedulePostingWriteReceipt
    ) async throws -> String {
        do {
            _ = try await operation()
        } catch let refusal as SchedulePostingRefusal {
            return try #require(refusal.errorDescription)
        }
        throw SchedulePostingTestFailure.expectedRejection
    }
}

private enum SchedulePostingTestFailure: Error {
    case expectedRejection
}
