import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
@Suite("Schedule auto-post refusal persistence")
struct ScheduleAutoPostRefusalPersistenceTests {
    private let helpers = ScheduleAdvancementTests()
    private static let today = "2026-09-30"
    private static let budgetID = "budget"
    private static let deletingActions = #"[{"op":"link-schedule","value":"rent"},{"op":"delete-transaction","value":""}]"#

    private func refusedFixture() throws -> (url: URL, database: BudgetDatabase) {
        try helpers.makeDatabase(
            extraSQL: helpers.oneTimeScheduleSQL(
                scheduleID: "rent", dayID: Self.today, amount: -10_000, actionsJSON: Self.deletingActions
            )
        )
    }

    private func refusal(
        _ id: String = "rent", day: String = "2026-09-30", _ reason: SchedulePostingRefusal = .ruleDeletesTransaction
    ) -> ScheduleAutoPostRefusal {
        ScheduleAutoPostRefusal(scheduleID: id, scheduleName: id, occurrenceDayID: day, refusal: reason)
    }

    @Test func aFinishedRunStoresRefusalsAndAReopenedDatabaseReadsThem() async throws {
        let fixture = try refusedFixture()

        let result = try await fixture.database.advanceSchedules(budgetID: Self.budgetID, today: Self.today)

        #expect(result.refusalsReplaced)
        #expect(try await fixture.database.scheduleAutoPostRefusals() == [refusal()])
        let reopened = try BudgetDatabase(databaseURL: fixture.url, localNodeID: "reopened-node")
        #expect(try await reopened.scheduleAutoPostRefusals() == [refusal()])
    }

    @Test func aNewSuccessfulRunReplacesTheStoredSet() async throws {
        let fixture = try refusedFixture()
        _ = try await fixture.database.advanceSchedules(budgetID: Self.budgetID, today: Self.today)

        // The next day's run refuses the same missed occurrence again; the set is replaced, not appended.
        _ = try await fixture.database.advanceSchedules(budgetID: Self.budgetID, today: "2026-10-01")

        #expect(try await fixture.database.scheduleAutoPostRefusals() == [refusal(day: "2026-09-30")])
    }

    @Test func aFailedSyncRunKeepsTheStoredRefusals() async throws {
        let fixture = try refusedFixture()
        _ = try await fixture.database.advanceSchedules(budgetID: Self.budgetID, today: Self.today)

        _ = try await fixture.database.advanceSchedules(
            budgetID: Self.budgetID, today: "2026-10-01", postingAllowed: false
        )

        #expect(try await fixture.database.scheduleAutoPostRefusals() == [refusal()])
    }

    @Test func removalDeletesOnlyTheExactOccurrence() async throws {
        let fixture = try refusedFixture()
        _ = try await fixture.database.advanceSchedules(budgetID: Self.budgetID, today: Self.today)

        try await fixture.database.removeScheduleAutoPostRefusals([refusal(day: "2026-09-01")])
        #expect(try await fixture.database.scheduleAutoPostRefusals() == [refusal()])
        try await fixture.database.removeScheduleAutoPostRefusals([refusal()])
        #expect(try await fixture.database.scheduleAutoPostRefusals().isEmpty)
    }

    @Test func aBudgetWithoutTheTableReadsNoRefusals() async throws {
        let fixture = try helpers.makeDatabase()
        #expect(try await fixture.database.scheduleAutoPostRefusals().isEmpty)
        try await fixture.database.removeScheduleAutoPostRefusals([refusal()])
    }

    @Test func everyRefusalReasonRoundTripsThroughItsRawValue() {
        let all: [SchedulePostingRefusal] = [
            .invalidCommand, .unsupportedOccurrence, .accountUnavailable, .occurrenceUnavailable,
            .occurrenceDateMismatch, .draftMismatch, .ruleDeletesTransaction, .ruleChangedScheduleLink,
            .unsupportedBudgetSchema, .referencedRowUnavailable
        ]
        for reason in all {
            #expect(SchedulePostingRefusal(rawValue: reason.rawValue) == reason)
        }
    }

    // MARK: Reconciler

    private func loaded(
        nextDate: String?, status: ScheduleStatus, completed: Bool = false, present: Bool = true
    ) async throws -> LoadedSchedules {
        let fixture = try helpers.makeDatabase(extraSQL: present ? helpers.oneTimeScheduleSQL(
            scheduleID: "rent", dayID: nextDate ?? Self.today, amount: -10_000, actionsJSON: Self.deletingActions
        ) + (completed ? "UPDATE schedules SET completed = 1 WHERE id = 'rent';" : "") : "")
        let schedules = try await fixture.database.fetchSchedules(budgetID: Self.budgetID, today: Self.today)
        if present { #expect(schedules.detail(id: "rent")?.status == status) }
        return schedules
    }

    @Test func aRefusalStaysWhileTheSameOccurrenceIsStillDue() async throws {
        let schedules = try await loaded(nextDate: Self.today, status: .due)
        #expect(ScheduleAutoPostRefusalReconciler.retained([refusal()], in: schedules) == [refusal()])
    }

    @Test func aRefusalStaysWhileTheSameOccurrenceIsStillMissed() async throws {
        let schedules = try await loaded(nextDate: "2026-09-25", status: .missed)
        let stored = refusal(day: "2026-09-25")
        #expect(ScheduleAutoPostRefusalReconciler.retained([stored], in: schedules) == [stored])
    }

    @Test func aRefusalEndsWhenTheNextDateMoved() async throws {
        let schedules = try await loaded(nextDate: "2026-09-25", status: .missed)
        #expect(ScheduleAutoPostRefusalReconciler.retained([refusal(day: "2026-09-20")], in: schedules).isEmpty)
    }

    @Test func aRefusalEndsWhenTheScheduleIsCompletedOrDeleted() async throws {
        let completed = try await loaded(nextDate: Self.today, status: .completed, completed: true)
        #expect(ScheduleAutoPostRefusalReconciler.retained([refusal()], in: completed).isEmpty)
        let missing = try await loaded(nextDate: nil, status: .due, present: false)
        #expect(ScheduleAutoPostRefusalReconciler.retained([refusal()], in: missing).isEmpty)
    }

    @Test func aRefusalEndsWhenTheOccurrenceIsPosted() async throws {
        let fixture = try helpers.makeDatabase(
            extraSQL: helpers.oneTimeScheduleSQL(scheduleID: "rent", dayID: Self.today, amount: -10_000)
                + "INSERT INTO transactions (id, acct, date, amount, schedule) VALUES ('t', 'checking', 20260930, -10000, 'rent');"
        )
        let schedules = try await fixture.database.fetchSchedules(budgetID: Self.budgetID, today: Self.today)
        #expect(schedules.detail(id: "rent")?.status == .paid)
        #expect(ScheduleAutoPostRefusalReconciler.retained([refusal()], in: schedules).isEmpty)
    }
}

@MainActor
@Suite("Schedule auto-post refusals in the store")
struct ScheduleAutoPostRefusalStoreTests {
    private let support = LocalFirstActualStoreTests()

    private static var refusalSchedulesSQL: String {
        // Delete rule: automatic posting refuses it on every run.
        ScheduleAdvancementTests.storeScheduleSQL
            .replacingOccurrences(
                of: #"'[{"op":"link-schedule","value":"rent"}]'"#,
                with: #"'[{"op":"link-schedule","value":"rent"},{"op":"delete-transaction","value":""}]'"#
            )
    }

    @Test func refusalsSurviveARelaunchTheSameDayAndReloadOnRefresh() async throws {
        let bundle = try await support.makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.refusalSchedulesSQL)
        let store = bundle.store
        store.openedServerURLString = nil
        let database = try #require(store.database)
        let today = TestLocalDay.today()

        await store.advanceSchedulesAfterSync(
            budgetID: "group-1", database: database, generation: store.budgetSessionGeneration
        )
        #expect(store.scheduleAutoPostRefusals.map(\.scheduleID) == ["rent"])

        // A relaunch loses the in-memory copy, and today's run is skipped by the marker.
        store.scheduleAutoPostRefusals = []
        await store.advanceSchedulesAfterSync(
            budgetID: "group-1", database: database, generation: store.budgetSessionGeneration
        )
        #expect(store.scheduleAutoPostRefusals.isEmpty)

        _ = try await store.refreshSchedules(budgetID: "group-1", asOf: today)
        #expect(store.scheduleAutoPostRefusals.map(\.scheduleID) == ["rent"])
        #expect(store.scheduleAutoPostRefusals.first?.refusal == .ruleDeletesTransaction)
    }

    @Test func aRefreshDropsAndForgetsARefusalOnceTheScheduleIsDeletedElsewhere() async throws {
        let bundle = try await support.makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.refusalSchedulesSQL)
        let store = bundle.store
        store.openedServerURLString = nil
        let database = try #require(store.database)
        await store.advanceSchedulesAfterSync(
            budgetID: "group-1", database: database, generation: store.budgetSessionGeneration
        )
        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in try db.execute(sql: "UPDATE schedules SET tombstone = 1 WHERE id = 'rent'") }

        _ = try await store.refreshSchedules(budgetID: "group-1", asOf: TestLocalDay.today())

        #expect(store.scheduleAutoPostRefusals.isEmpty)
        #expect(try await database.scheduleAutoPostRefusals().isEmpty)
    }

    @Test func resetClearsInMemoryRefusalsWithoutLeakingThemIntoAnotherBudget() async throws {
        let bundle = try await support.makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.refusalSchedulesSQL)
        let store = bundle.store
        store.openedServerURLString = nil
        let database = try #require(store.database)
        await store.advanceSchedulesAfterSync(
            budgetID: "group-1", database: database, generation: store.budgetSessionGeneration
        )
        #expect(!store.scheduleAutoPostRefusals.isEmpty)

        store.reset()

        #expect(store.scheduleAutoPostRefusals.isEmpty)
        // Another budget is another database file, which has no such table rows.
        let other = try BudgetDatabase(databaseURL: try support.makeSQLiteFixture(), localNodeID: "other")
        #expect(try await other.scheduleAutoPostRefusals().isEmpty)
    }
}
