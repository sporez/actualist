import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
@Suite("Ended schedule next date")
struct ScheduleEndedNextDateTests {
    private let support = LocalFirstActualStoreTests()

    @Test func creatingAnEndedWeeklyScheduleStoresItsLastOccurrence() async throws {
        let recurrence = try ActualScheduleRecurrence(
            startDayID: "2026-08-03",
            frequency: .weekly,
            ending: .onDate("2026-09-26")
        )
        let url = try support.makeSQLiteFixture(extraSQL: Self.scheduleSchemaSQL)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "ended-node")
        let command = ScheduleCreateCommand(
            budgetID: "budget",
            identity: ScheduleCreateIdentity(scheduleID: "ended", ruleID: "ended-rule", nextDateID: "ended-next"),
            name: "Ended",
            definition: ScheduleDefinitionDraft(
                accountID: "checking",
                payeeMappingID: nil,
                amount: .exact(-5_000),
                dateRule: .recurring(recurrence, operation: "is")
            ),
            postsTransaction: false,
            customUpcomingLength: nil,
            asOfDayID: "2026-09-27"
        )

        _ = try await database.createSchedule(command)

        let queue = try DatabaseQueue(path: url.path)
        let stored = try queue.readSync { db in
            try String.fetchOne(db, sql: "SELECT local_next_date FROM schedules_next_date WHERE id = 'ended-next'")
        }
        #expect(stored == "20260921")
    }

    @Test func initialAndUpdatedNextDatesFallBackToTheLastOccurrence() throws {
        let ended = try ActualScheduleRecurrence(
            startDayID: "2026-08-03",
            frequency: .weekly,
            ending: .afterOccurrences(2)
        )
        let rule = ScheduleDateRule.recurring(ended, operation: "is")

        #expect(try ScheduleRuleMutation.initialNextDate(for: rule, asOf: "2026-09-27") == "2026-08-10")
        #expect(try ScheduleRuleMutation.updateNextDate(
            for: rule, asOf: "2026-09-27", currentEffectiveDate: "2026-08-03"
        ) == "2026-08-10")
        #expect(try ScheduleRuleMutation.updateNextDate(
            for: rule, asOf: "2026-09-27", currentEffectiveDate: "2026-08-10"
        ) == nil)
    }

    private static var scheduleSchemaSQL: String {
        """
        CREATE TABLE rules (
            id TEXT PRIMARY KEY, stage TEXT, conditions TEXT, actions TEXT,
            conditions_op TEXT DEFAULT 'and', tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE schedules (
            id TEXT PRIMARY KEY, rule TEXT, name TEXT, active INTEGER DEFAULT 0,
            completed INTEGER DEFAULT 0, posts_transaction INTEGER DEFAULT 0,
            custom_upcoming_length TEXT, sort_order REAL, tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE schedules_next_date (
            id TEXT PRIMARY KEY, schedule_id TEXT, local_next_date INTEGER,
            local_next_date_ts INTEGER, base_next_date INTEGER,
            base_next_date_ts INTEGER, tombstone INTEGER DEFAULT 0
        );
        """
    }
}
