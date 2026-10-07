import Foundation
import GRDB
import Testing
@testable import Actualist

/// Apply Templates follows upstream `schedule-template.ts`: `getNextDate` honors a
/// schedule's end condition (and falls back to the last occurrence once it has
/// ended), so a schedule created with an end date must not abort the whole plan
/// (main-to-dev audit F-7, decision D8, remediation item 4.5).
@MainActor
@Suite("Budget template ended schedules")
struct BudgetTemplateEndedScheduleTests {
    private let support = LocalFirstActualStoreTests()
    private static let monthly = #""start":"2026-01-01","frequency":"monthly""#

    @Test func scheduleEndingAfterTheBudgetMonthMatchesTheSameScheduleWithoutAnEnd() async throws {
        let open = try await appliedAmount(dateDefinition: "{\(Self.monthly)}")
        let ending = try await appliedAmount(
            dateDefinition: "{\(Self.monthly),\"endMode\":\"on_date\",\"endDate\":\"2026-12-01\"}"
        )
        let counted = try await appliedAmount(
            dateDefinition: "{\(Self.monthly),\"endMode\":\"after_n_occurrences\",\"endOccurrences\":10}"
        )

        #expect(open != nil)
        #expect(ending == open)
        #expect(counted == open)
    }

    @Test func scheduleThatAlreadyEndedUsesItsLastOccurrenceAndContributesNothing() async throws {
        let amount = try await appliedAmount(
            dateDefinition: "{\(Self.monthly),\"endMode\":\"after_n_occurrences\",\"endOccurrences\":3}"
        )
        let onDate = try await appliedAmount(
            dateDefinition: "{\(Self.monthly),\"endMode\":\"on_date\",\"endDate\":\"2026-03-15\"}"
        )

        #expect(amount == onDate)
    }

    @Test func endingBeforeTheFirstOccurrenceStillFailsThePlan() async throws {
        let database = try makeDatabase(
            dateDefinition: #"{"start":"2026-06-01","frequency":"monthly","endMode":"on_date","endDate":"2026-05-01"}"#
        )
        var builder = LocalFirstSyncMessageBuilder()

        do {
            _ = try await database.budgetTemplateApply(
                command: .category("groceries"), month: "2026-07", builder: &builder
            )
            Issue.record("Expected a schedule that ends before it starts to fail the plan")
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            #expect(reason == "schedule")
        }
    }

    /// Applies the template for July 2026 and returns the stored budgeted amount, or
    /// nil when the plan wrote nothing.
    private func appliedAmount(dateDefinition: String) async throws -> Int? {
        let url = try makeFixtureURL(dateDefinition: dateDefinition)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node1")
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateApply(
            command: .category("groceries"), month: "2026-07", builder: &builder
        ).messages
        if !messages.isEmpty {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        }
        return try await DatabaseQueue(path: url.path).read { db in
            try Int.fetchOne(
                db, sql: "SELECT amount FROM zero_budgets WHERE category = 'groceries' AND month = 202607"
            )
        }
    }

    private func makeDatabase(dateDefinition: String) throws -> BudgetDatabase {
        try BudgetDatabase(databaseURL: makeFixtureURL(dateDefinition: dateDefinition), localNodeID: "node1")
    }

    private func makeFixtureURL(dateDefinition: String) throws -> URL {
        try support.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"schedule","scheduleId":"rent","priority":0}]'
            WHERE id = 'groceries';
            CREATE TABLE rules (id TEXT PRIMARY KEY, conditions TEXT, actions TEXT, tombstone INTEGER);
            INSERT INTO rules VALUES (
                'rent-rule',
                '[{"op":"is","field":"amount","value":-125000},{"op":"is","field":"date","value":\(dateDefinition)}]',
                '[{"op":"link-schedule","value":"rent"}]',
                0
            );
            CREATE TABLE schedules (id TEXT PRIMARY KEY, name TEXT, rule TEXT, completed INTEGER, tombstone INTEGER);
            INSERT INTO schedules VALUES ('rent', 'Rent', 'rent-rule', 0, 0);
            """)
    }
}
