import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
@Suite("Schedule creation row identity")
struct ScheduleCreationIdentityTests {
    private let support = LocalFirstActualStoreTests()

    /// Actual's `db.insert` filters `id` out of the field messages, so a created
    /// schedule's identity is only the CRDT row id.
    @Test func createWritesNoExplicitIdColumnMessagesYetCreatesTheRows() async throws {
        let url = try support.makeSQLiteFixture(extraSQL: ScheduleEndedNextDateTests.scheduleSchemaSQL)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "identity-node")
        let command = ScheduleCreateCommand(
            budgetID: "budget",
            identity: ScheduleCreateIdentity(scheduleID: "new", ruleID: "new-rule", nextDateID: "new-next"),
            name: "Rent",
            definition: ScheduleDefinitionDraft(
                accountID: "checking",
                payeeMappingID: nil,
                amount: .exact(-5_000),
                dateRule: .oneTime(dayID: "2026-10-01", operation: "is")
            ),
            postsTransaction: false,
            customUpcomingLength: nil,
            asOfDayID: "2026-09-27"
        )

        _ = try await database.createSchedule(command)

        let queue = try DatabaseQueue(path: url.path)
        let idMessages = try queue.readSync { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE column = 'id'")
        }
        let identities: [String?] = try queue.readSync { db in
            [
                try String.fetchOne(db, sql: "SELECT id FROM schedules WHERE id = 'new'"),
                try String.fetchOne(db, sql: "SELECT id FROM rules WHERE id = 'new-rule'"),
                try String.fetchOne(db, sql: "SELECT id FROM schedules_next_date WHERE id = 'new-next'"),
                try String.fetchOne(db, sql: "SELECT schedule_id FROM schedules_next_date WHERE id = 'new-next'")
            ]
        }
        #expect(idMessages == 0)
        #expect(identities == ["new", "new-rule", "new-next", "new"])
    }
}
