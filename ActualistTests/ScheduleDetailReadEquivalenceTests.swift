import Foundation
import GRDB
import Testing
@testable import Actualist

/// Phase 5.2: schedule advancement reads one schedule's detail per step
/// instead of loading every schedule. The all-schedules read is the oracle.
@MainActor
struct ScheduleDetailReadEquivalenceTests {
    private let support = LocalFirstActualStoreTests()
    private let helper = ScheduleAdvancementTests()
    private static let today = "2026-09-30"
    private static let budgetID = "budget"

    private func fixtureSQL(oneTimeCount: Int) -> String {
        var sql = helper.oneTimeScheduleSQL(
            scheduleID: "once-0",
            dayID: "2026-09-30",
            amount: -10_000,
            includeSchema: false
        )
        for index in 1..<max(oneTimeCount, 2) {
            let days = ["2026-09-01", "2026-09-30", "2026-10-02", "2026-12-25", "2025-03-04"]
            sql += helper.oneTimeScheduleSQL(
                scheduleID: "once-\(index)",
                dayID: days[index % days.count],
                amount: -1_000 * (index + 1),
                includeSchema: false
            )
        }
        sql += helper.recurringScheduleSQL(
            scheduleID: "yearly",
            startDayID: "2026-01-15",
            frequency: "yearly",
            nextDayID: "2026-01-15",
            amount: -5_000
        ).replacingOccurrences(of: ScheduleAdvancementTests.schemaSQL, with: "")
        sql += """
            INSERT INTO schedules VALUES ('twin', 'once-0-rule', 'Twin', 0, 1, NULL, 1, 0);
            INSERT INTO schedules_next_date VALUES ('twin-next', 'twin', 20260930, 100, 20260930, 100, 0);
            INSERT INTO schedules VALUES ('no-rule-row', 'missing-rule', 'Orphan', 0, 1, NULL, 1, 0);
            INSERT INTO schedules VALUES ('no-next-date', 'once-1-rule', 'Lonely', 0, 1, NULL, 1, 0);
            INSERT INTO schedules VALUES ('ambiguous', 'once-2-rule', 'Ambiguous', 0, 1, NULL, 1, 0);
            INSERT INTO schedules_next_date VALUES ('amb-1', 'ambiguous', 20260930, 100, 20260930, 100, 0);
            INSERT INTO schedules_next_date VALUES ('amb-2', 'ambiguous', 20261001, 100, 20261001, 100, 0);
            INSERT INTO schedules VALUES ('done', 'once-3-rule', 'Done', 1, 1, NULL, 1, 0);
            INSERT INTO schedules VALUES ('gone', 'once-0-rule', 'Gone', 0, 1, NULL, 1, 1);
            """
        return sql
    }

    private func database(oneTimeCount: Int) throws -> BudgetDatabase {
        try BudgetDatabase(
            databaseURL: support.makeSQLiteFixture(extraSQL: ScheduleAdvancementTests.schemaSQL + fixtureSQL(oneTimeCount: oneTimeCount)),
            localNodeID: "schedule-detail-node"
        )
    }

    @Test func singleScheduleDetailMatchesTheAllSchedulesRead() async throws {
        let database = try database(oneTimeCount: 6)
        let all = try await database.fetchSchedules(budgetID: Self.budgetID, today: Self.today)
        let ids = Array(all.detailsByID.keys) + ["gone", "never-existed"]
        #expect(all.detailsByID.count >= 10)
        for id in ids {
            let single = try await database.fetchScheduleDetail(
                budgetID: Self.budgetID,
                scheduleID: id,
                today: Self.today
            )
            #expect(single == all.detail(id: id), "\(id)")
        }
        #expect(all.detail(id: "gone") == nil)
        #expect(all.detail(id: "twin")?.capabilities.canEditMetadata == false)
    }

    @Test func singleScheduleReadFiltersScheduleRuleAndNextDateRows() async throws {
        let database = try database(oneTimeCount: 6)
        let log = StatementLog()
        try await database.startStatementTraceForTesting(log)
        _ = try await database.fetchScheduleDetail(
            budgetID: Self.budgetID,
            scheduleID: "once-1",
            today: Self.today
        )
        try await database.stopStatementTraceForTesting()
        let statements = log.statements
        /// Statements reading `table` that carry none of the single-row filters.
        func unfiltered(_ table: String, filters: [String]) -> [String] {
            statements.filter { statement in
                statement.contains("FROM \(table)")
                    && !statement.contains("FROM \(table)_")
                    && !filters.contains(where: statement.contains)
            }
        }
        #expect(unfiltered("schedules", filters: ["AND id = ?", "rule = ?"]).isEmpty)
        #expect(unfiltered("schedules_next_date", filters: ["schedule_id = ?"]).isEmpty)
        #expect(unfiltered("rules", filters: ["id IN (?"]).isEmpty)
        #expect(statements.contains { $0.contains("FROM rules") })
    }

    @Test func advancementScansAllSchedulesOnceForOrdering() async throws {
        let database = try database(oneTimeCount: 12)
        let log = StatementLog()
        try await database.startStatementTraceForTesting(log)
        let result = try await database.advanceSchedules(budgetID: Self.budgetID, today: Self.today)
        try await database.stopStatementTraceForTesting()
        let fullNextDateScans = log.statements.filter {
            $0.contains("FROM schedules_next_date") && !$0.contains("schedule_id = ?")
        }.count
        #expect(!result.receipts.isEmpty)
        #expect(fullNextDateScans == 1, "full next-date scans \(fullNextDateScans)")
    }
}
