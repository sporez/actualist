import Testing
@testable import Actualist

@MainActor
@Suite("Budget template database schedule decoder")
struct BudgetTemplateScheduleDecoderTests {
    private let support = LocalFirstActualStoreTests()

    @Test func databaseDecoderRefusesPatternsAndEndings() async throws {
        let definitions = [
            (
                "patterns",
                #"{"start":"2026-01-01","frequency":"monthly","patterns":[{"type":"day","value":15}]}"#,
                "schedule date patterns are not supported locally yet"
            ),
            (
                "ending",
                #"{"start":"2026-01-01","frequency":"monthly","endMode":"on_date","endDate":"2026-12-01"}"#,
                "schedule end dates are not supported locally yet"
            )
        ]

        for (label, definition, expectedReason) in definitions {
            let database = try makeDatabase(label: label, dateDefinition: definition)
            var builder = LocalFirstSyncMessageBuilder()
            do {
                _ = try await database.budgetTemplateMessages(
                    command: .category("groceries"),
                    month: "2026-07",
                    builder: &builder
                )
                Issue.record("Expected \(label) schedule recurrence to be refused")
            } catch LocalFirstError.unsupportedTemplate(let reason) {
                #expect(reason == expectedReason)
            }
            #expect(try await database.pendingLocalSyncMessageCount() == 0)
        }
    }

    @Test func databaseDecoderRequiresWeekendModeWhenSkippingWeekends() async throws {
        let database = try makeDatabase(
            label: "weekend",
            dateDefinition: #"{"start":"2026-01-03","frequency":"weekly","skipWeekend":true}"#
        )
        var builder = LocalFirstSyncMessageBuilder()
        do {
            _ = try await database.budgetTemplateMessages(
                command: .category("groceries"),
                month: "2026-07",
                builder: &builder
            )
            Issue.record("Expected missing weekend mode to be refused")
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            #expect(reason == "schedule")
        }
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
    }

    private func makeDatabase(
        label: String,
        dateDefinition: String
    ) throws -> BudgetDatabase {
        let url = try support.makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"schedule","scheduleId":"schedule-\(label)","priority":0}]'
            WHERE id = 'groceries';
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'rule-\(label)',
                '[{"op":"is","field":"amount","value":-125000},{"op":"is","field":"date","value":\(dateDefinition)}]',
                '[{"op":"link-schedule","value":"schedule-\(label)"}]',
                0
            );
            CREATE TABLE schedules (
                id TEXT PRIMARY KEY,
                name TEXT,
                rule TEXT,
                completed INTEGER,
                tombstone INTEGER
            );
            INSERT INTO schedules VALUES (
                'schedule-\(label)',
                'Schedule \(label)',
                'rule-\(label)',
                0,
                0
            );
            """)
        return try BudgetDatabase(databaseURL: url)
    }
}
