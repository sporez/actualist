import Foundation
import Testing
@testable import Actualist

@MainActor
@Suite("Budget database schedule reads")
struct BudgetDatabaseScheduleReadTests {
    private let support = LocalFirstActualStoreTests()

    @Test func localNextDateWinsOnlyAtEqualTimestampAndBaseWinsAfterReset() async throws {
        let loaded = try await makeLoadedSchedules()
        #expect(loaded.detail(id: "due")?.effectiveNextDate == "2026-09-27")
        #expect(loaded.detail(id: "base-reset")?.effectiveNextDate == "2026-10-05")
        #expect(loaded.detail(id: "due")?.occurrenceIdentity.localNextDateTimestamp == "100")
    }

    @Test func statusPrecedenceAndOccurrenceMatchingMirrorPinnedReadRules() async throws {
        let loaded = try await makeLoadedSchedules()
        #expect(loaded.detail(id: "due")?.status == .due)
        #expect(loaded.detail(id: "missed")?.status == .missed)
        #expect(loaded.detail(id: "upcoming")?.status == .upcoming)
        #expect(loaded.detail(id: "scheduled")?.status == .scheduled)
        #expect(loaded.detail(id: "custom-short")?.status == .scheduled)
        #expect(loaded.detail(id: "manual-paid")?.status == .paid)
        #expect(loaded.detail(id: "auto-exact")?.status == .upcoming)
        #expect(loaded.detail(id: "completed")?.status == .completed)
    }

    @Test func exactApproximateAndRangeAmountsUseActualPostingValues() async throws {
        let loaded = try await makeLoadedSchedules()
        #expect(loaded.detail(id: "due")?.amount == .exact(-10_000))
        #expect(loaded.detail(id: "upcoming")?.amount == .approximate(-2_500))
        #expect(
            loaded.detail(id: "scheduled")?.amount
                == .range(lower: -5_001, upper: -3_000, postingAmount: -4_000)
        )
    }

    @Test func closedAndMissingReferencesRemainVisible() async throws {
        let loaded = try await makeLoadedSchedules()
        #expect(loaded.detail(id: "scheduled")?.account.availability == .closed)
        #expect(loaded.detail(id: "scheduled")?.account.name == "Closed")
        #expect(loaded.detail(id: "missing-refs")?.account.availability == .missing)
        #expect(loaded.detail(id: "missing-refs")?.payee.isMissing == true)
        #expect(loaded.schedules.contains { $0.id == "missing-refs" })
    }

    @Test func mappedPayeeAndRawUnsupportedJSONArePreserved() async throws {
        let loaded = try await makeLoadedSchedules()
        #expect(loaded.detail(id: "due")?.payee.id == "landlord")
        #expect(loaded.detail(id: "due")?.payee.name == "Landlord")
        let unsupported = try #require(loaded.detail(id: "unsupported"))
        #expect(unsupported.rawConditionsJSON?.contains("fortnightly") == true)
        #expect(unsupported.rawActionsJSON?.contains("custom-action") == true)
        #expect(unsupported.unsupportedReasons.contains(.unsupportedDate))
        #expect(unsupported.unsupportedReasons.contains(.unsupportedActions))
        #expect(!unsupported.capabilities.canEdit)
    }

    @Test func capabilitiesRemainOperationSpecificForUnsupportedDefinitions() async throws {
        let loaded = try await makeLoadedSchedules()
        let detail = try #require(loaded.detail(id: "skip-safe"))
        #expect(detail.unsupportedReasons.contains(.missingAmount))
        #expect(detail.unsupportedReasons.contains(.unsupportedActions))
        #expect(detail.capabilities.canSkip)
        #expect(detail.capabilities.canDelete)
        #expect(!detail.capabilities.canEdit)
        #expect(!detail.capabilities.canPost)
        let ambiguous = try #require(loaded.detail(id: "ambiguous-date"))
        #expect(ambiguous.unsupportedReasons.contains(.unsupportedDate))
        #expect(!ambiguous.capabilities.canSkip)
    }

    @Test func tombstonesAreOmittedAndDeterministicSortUsesCompletionDateAndID() async throws {
        let loaded = try await makeLoadedSchedules()
        #expect(!loaded.schedules.contains { $0.id == "deleted" })
        #expect(loaded.schedules.last?.id == "completed")
        let active = loaded.schedules.filter { $0.status != .completed }
        #expect(active == active.sorted { ($0.effectiveNextDate ?? "9999") < ($1.effectiveNextDate ?? "9999") || ($0.effectiveNextDate == $1.effectiveNextDate && $0.id < $1.id) })
    }

    @Test func missingOptionalColumnsAndCorruptLinkageStayReadable() async throws {
        let url = try support.makeSQLiteFixture(extraSQL: """
            CREATE TABLE schedules (id TEXT PRIMARY KEY, rule TEXT);
            INSERT INTO schedules VALUES ('legacy', 'missing-rule');
            """)
        let database = try BudgetDatabase(databaseURL: url)
        let loaded = try await database.fetchSchedules(
            budgetID: "legacy-budget",
            today: "2026-09-27"
        )
        let detail = try #require(loaded.detail(id: "legacy"))
        #expect(detail.status == .scheduled)
        #expect(detail.unsupportedReasons.contains(.missingRule))
        #expect(detail.unsupportedReasons.contains(.missingNextDate))
        #expect(!detail.capabilities.canDelete)
        #expect(detail.name == nil)
    }

    private func makeLoadedSchedules() async throws -> LoadedSchedules {
        let url = try support.makeSQLiteFixture(extraSQL: fixtureSQL)
        let database = try BudgetDatabase(databaseURL: url)
        return try await database.fetchSchedules(
            budgetID: "budget",
            today: "2026-09-27"
        )
    }

    private var fixtureSQL: String {
        """
        ALTER TABLE transactions ADD COLUMN schedule TEXT;
        ALTER TABLE payee_mapping ADD COLUMN targetId TEXT;
        CREATE TABLE payees (
            id TEXT PRIMARY KEY,
            name TEXT,
            tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE rules (
            id TEXT PRIMARY KEY,
            conditions TEXT,
            actions TEXT,
            tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE schedules (
            id TEXT PRIMARY KEY,
            rule TEXT,
            name TEXT,
            completed INTEGER DEFAULT 0,
            posts_transaction INTEGER DEFAULT 0,
            custom_upcoming_length TEXT,
            sort_order REAL,
            tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE schedules_next_date (
            id TEXT PRIMARY KEY,
            schedule_id TEXT,
            local_next_date INTEGER,
            local_next_date_ts INTEGER,
            base_next_date INTEGER,
            base_next_date_ts INTEGER,
            tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
        INSERT INTO preferences VALUES ('upcomingScheduledTransactionLength', '7');
        INSERT INTO accounts VALUES ('closed', 'Closed', 0, 1, 0, 2);
        INSERT INTO payees VALUES ('landlord', 'Landlord', 0);
        INSERT INTO payees VALUES ('gone-payee', 'Coincident ID', 0);
        INSERT INTO payee_mapping (id, transferId, targetId) VALUES ('landlord-map', NULL, 'landlord');

        INSERT INTO rules VALUES ('exact-rule',
          '[{"op":"is","field":"account","value":"checking"},{"op":"is","field":"description","value":"landlord-map"},{"op":"is","field":"amount","value":-10000},{"op":"is","field":"date","value":"2026-09-27"}]',
          '[{"op":"link-schedule","value":"due"}]', 0);
        INSERT INTO rules VALUES ('approx-rule',
          '[{"op":"is","field":"account","value":"checking"},{"op":"isapprox","field":"amount","value":-2500},{"op":"isapprox","field":"date","value":{"start":"2026-09-29","frequency":"monthly"}}]',
          '[{"op":"link-schedule","value":"upcoming"}]', 0);
        INSERT INTO rules VALUES ('range-rule',
          '[{"op":"is","field":"account","value":"closed"},{"op":"isbetween","field":"amount","value":{"num1":-5001,"num2":-3000}},{"op":"isapprox","field":"date","value":{"start":"2026-10-15","frequency":"monthly"}}]',
          '[{"op":"link-schedule","value":"scheduled"}]', 0);
        INSERT INTO rules VALUES ('missing-rule-ref',
          '[{"op":"is","field":"account","value":"gone"},{"op":"is","field":"description","value":"gone-payee"},{"op":"is","field":"amount","value":-100},{"op":"is","field":"date","value":"2026-09-28"}]',
          '[{"op":"link-schedule","value":"missing-refs"}]', 0);
        INSERT INTO rules VALUES ('unsupported-rule',
          '[{"op":"is","field":"amount","value":-100},{"op":"isapprox","field":"date","value":{"start":"2026-09-28","frequency":"fortnightly"}}]',
          '[{"op":"link-schedule","value":"unsupported"},{"op":"custom-action","value":{"keep":true}}]', 0);
        INSERT INTO rules VALUES ('skip-safe-rule',
          '[{"op":"is","field":"account","value":"checking"},{"op":"isapprox","field":"date","value":{"start":"2026-10-01","frequency":"monthly"}}]',
          '[{"op":"link-schedule","value":"skip-safe"},{"op":"custom-action","value":{"keep":true}}]', 0);
        INSERT INTO rules VALUES ('ambiguous-date-rule',
          '[{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":-100},{"op":"isapprox","field":"date","value":{"start":"2026-10-01","frequency":"monthly"}},{"op":"is","field":"date","value":"2026-10-01"}]',
          '[{"op":"link-schedule","value":"ambiguous-date"}]', 0);

        INSERT INTO schedules VALUES ('due', 'exact-rule', 'Due', 0, 0, NULL, 1, 0);
        INSERT INTO schedules VALUES ('base-reset', 'exact-rule', 'Reset', 0, 0, NULL, 2, 0);
        INSERT INTO schedules VALUES ('missed', 'approx-rule', 'Missed', 0, 0, NULL, 3, 0);
        INSERT INTO schedules VALUES ('upcoming', 'approx-rule', 'Upcoming', 0, 0, NULL, 4, 0);
        INSERT INTO schedules VALUES ('scheduled', 'range-rule', 'Scheduled', 0, 0, NULL, 5, 0);
        INSERT INTO schedules VALUES ('manual-paid', 'approx-rule', 'Manual Paid', 0, 0, NULL, 6, 0);
        INSERT INTO schedules VALUES ('auto-exact', 'approx-rule', 'Auto', 0, 1, NULL, 7, 0);
        INSERT INTO schedules VALUES ('completed', 'exact-rule', 'Completed', 1, 0, NULL, 8, 0);
        INSERT INTO schedules VALUES ('missing-refs', 'missing-rule-ref', 'Missing refs', 0, 0, NULL, 9, 0);
        INSERT INTO schedules VALUES ('unsupported', 'unsupported-rule', 'Unsupported', 0, 0, NULL, 10, 0);
        INSERT INTO schedules VALUES ('custom-short', 'approx-rule', 'Custom short', 0, 0, '1', 11, 0);
        INSERT INTO schedules VALUES ('skip-safe', 'skip-safe-rule', 'Skip safe', 0, 0, NULL, 12, 0);
        INSERT INTO schedules VALUES ('ambiguous-date', 'ambiguous-date-rule', 'Ambiguous date', 0, 0, NULL, 13, 0);
        INSERT INTO schedules VALUES ('deleted', 'exact-rule', 'Deleted', 0, 0, NULL, 14, 1);

        INSERT INTO schedules_next_date VALUES ('nd-due', 'due', 20260927, 100, 20261001, 100, 0);
        INSERT INTO schedules_next_date VALUES ('nd-reset', 'base-reset', 20260927, 100, 20261005, 200, 0);
        INSERT INTO schedules_next_date VALUES ('nd-missed', 'missed', 20260920, 100, 20260920, 100, 0);
        INSERT INTO schedules_next_date VALUES ('nd-upcoming', 'upcoming', 20260929, 100, 20260929, 100, 0);
        INSERT INTO schedules_next_date VALUES ('nd-scheduled', 'scheduled', 20261015, 100, 20261015, 100, 0);
        INSERT INTO schedules_next_date VALUES ('nd-manual', 'manual-paid', 20260929, 100, 20260929, 100, 0);
        INSERT INTO schedules_next_date VALUES ('nd-auto', 'auto-exact', 20260929, 100, 20260929, 100, 0);
        INSERT INTO schedules_next_date VALUES ('nd-completed', 'completed', 20260927, 100, 20260927, 100, 0);
        INSERT INTO schedules_next_date VALUES ('nd-missing', 'missing-refs', 20260928, 100, 20260928, 100, 0);
        INSERT INTO schedules_next_date VALUES ('nd-unsupported', 'unsupported', 20260928, 100, 20260928, 100, 0);
        INSERT INTO schedules_next_date VALUES ('nd-custom-short', 'custom-short', 20260929, 100, 20260929, 100, 0);
        INSERT INTO schedules_next_date VALUES ('nd-skip-safe', 'skip-safe', 20261001, 100, 20261001, 100, 0);
        INSERT INTO schedules_next_date VALUES ('nd-ambiguous-date', 'ambiguous-date', 20261001, 100, 20261001, 100, 0);

        INSERT INTO transactions
          (id, acct, date, amount, category, tombstone, parent_id, is_parent, schedule)
          VALUES ('manual-payment', 'checking', 20260927, -2500, NULL, 0, NULL, 0, 'manual-paid');
        INSERT INTO transactions
          (id, acct, date, amount, category, tombstone, parent_id, is_parent, schedule)
          VALUES ('early-auto', 'checking', 20260928, -2500, NULL, 0, NULL, 0, 'auto-exact');
        INSERT INTO transactions
          (id, acct, date, amount, category, tombstone, parent_id, is_parent, schedule)
          VALUES ('orphan-upcoming', 'checking', 20260929, -2500, NULL, 0, 'missing-parent', 0, 'upcoming');
        INSERT INTO transactions
          (id, acct, date, amount, category, tombstone, parent_id, is_parent, schedule)
          VALUES ('completed-payment', 'checking', 20260927, -10000, NULL, 0, NULL, 0, 'completed');
        """
    }
}
