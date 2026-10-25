import Foundation
import Testing
@testable import Actualist

/// Actual runs schedule advancement after a failed or unauthorized sync too,
/// and skips only posting (`advanceSchedulesService(false)`). The day marker
/// and the persisted refusals change only after a run that may post.
@MainActor
@Suite("Schedule advancement after a failed sync")
struct ScheduleAdvancementSyncFailureTests {
    private let helpers = ScheduleAdvancementTests()
    private static let today = "2026-09-30"
    private static let budgetID = "budget"

    /// `lastScheduleRun`, or nil when the budget has no metadata file yet.
    private func marker(_ databaseURL: URL) -> String? {
        let url = databaseURL.deletingLastPathComponent().appending(path: "metadata.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["lastScheduleRun"] as? String
    }

    private func linkedTransactionSQL(scheduleID: String, dayID: String) -> String {
        """
        INSERT INTO transactions (id, acct, date, amount, schedule)
        VALUES ('\(scheduleID)-paid', 'checking', \(ScheduleAdvancementTests.packed(dayID)), -500, '\(scheduleID)');
        """
    }

    @Test func paidRecurringAdvancesWithoutPostingOrMarker() async throws {
        let fixture = try helpers.makeDatabase(
            extraSQL: helpers.recurringScheduleSQL(
                scheduleID: "gym", startDayID: "2026-09-27", frequency: "weekly",
                nextDayID: "2026-09-27", amount: -500
            ) + linkedTransactionSQL(scheduleID: "gym", dayID: "2026-09-27"),
            metadata: ["note": "retain-me"]
        )
        #expect(try await fixture.database.fetchSchedules(budgetID: Self.budgetID, today: Self.today)
            .detail(id: "gym")?.status == .paid)

        let result = try await fixture.database.advanceSchedules(
            budgetID: Self.budgetID, today: Self.today, postingAllowed: false
        )

        #expect(result.scheduleMutated)
        #expect(result.receipts.isEmpty)
        #expect(!result.refusalsReplaced)
        #expect(try helpers.scheduleTransactionCount("gym", fixture.url) == 1)
        #expect(try await fixture.database.fetchSchedules(budgetID: Self.budgetID, today: Self.today)
            .detail(id: "gym")?.effectiveNextDate == "2026-10-04")
        #expect(marker(fixture.url) == nil)
        #expect(try helpers.metadataObject(beside: fixture.url)["note"] as? String == "retain-me")
    }

    @Test func dueScheduleIsNotPostedAfterFailedSyncAndPostsOnTheLaterSuccessfulRun() async throws {
        let fixture = try helpers.makeDatabase(
            extraSQL: helpers.oneTimeScheduleSQL(scheduleID: "rent", dayID: Self.today, amount: -10_000)
        )

        let failed = try await fixture.database.advanceSchedules(
            budgetID: Self.budgetID, today: Self.today, postingAllowed: false
        )
        #expect(failed.receipts.isEmpty)
        #expect(try helpers.scheduleTransactionCount("rent", fixture.url) == 0)
        #expect(marker(fixture.url) == nil)

        let succeeded = try await fixture.database.advanceSchedules(budgetID: Self.budgetID, today: Self.today)
        #expect(succeeded.receipts.map(\.scheduleID) == ["rent"])
        #expect(try helpers.scheduleTransactionCount("rent", fixture.url) == 1)
        #expect(marker(fixture.url) == Self.today)
    }

    @Test func missedRecurringStaysOnItsMissedDateAfterFailedSync() async throws {
        let fixture = try helpers.makeDatabase(
            extraSQL: helpers.recurringScheduleSQL(
                scheduleID: "rent", startDayID: "2026-09-20", frequency: "weekly",
                nextDayID: "2026-09-20", amount: -10_000
            )
        )

        _ = try await fixture.database.advanceSchedules(
            budgetID: Self.budgetID, today: Self.today, postingAllowed: false
        )

        #expect(try helpers.scheduleTransactionCount("rent", fixture.url) == 0)
        let detail = try #require(
            try await fixture.database.fetchSchedules(budgetID: Self.budgetID, today: Self.today).detail(id: "rent")
        )
        #expect(detail.effectiveNextDate == "2026-09-20")
        #expect(detail.status == .missed)
    }

    @Test func pastPaidOneTimeScheduleCompletesAfterFailedSync() async throws {
        let fixture = try helpers.makeDatabase(
            extraSQL: helpers.oneTimeScheduleSQL(scheduleID: "once", dayID: "2026-09-20", amount: -500)
                + linkedTransactionSQL(scheduleID: "once", dayID: "2026-09-20")
        )

        let result = try await fixture.database.advanceSchedules(
            budgetID: Self.budgetID, today: Self.today, postingAllowed: false
        )

        #expect(result.scheduleMutated)
        #expect(try await fixture.database.fetchSchedules(budgetID: Self.budgetID, today: Self.today)
            .detail(id: "once")?.completed == true)
        #expect(marker(fixture.url) == nil)
    }

    @Test func aMarkerForTodaySkipsAFailedSyncRunToo() async throws {
        let fixture = try helpers.makeDatabase(
            extraSQL: helpers.recurringScheduleSQL(
                scheduleID: "gym", startDayID: "2026-09-27", frequency: "weekly",
                nextDayID: "2026-09-27", amount: -500
            ) + linkedTransactionSQL(scheduleID: "gym", dayID: "2026-09-27"),
            metadata: ["lastScheduleRun": Self.today]
        )

        let result = try await fixture.database.advanceSchedules(
            budgetID: Self.budgetID, today: Self.today, postingAllowed: false
        )

        #expect(result.skippedForToday)
        #expect(try await fixture.database.fetchSchedules(budgetID: Self.budgetID, today: Self.today)
            .detail(id: "gym")?.effectiveNextDate == "2026-09-27")
    }
}

@MainActor
@Suite("Schedule advancement after a failed store sync")
struct ScheduleAdvancementSyncFailureStoreTests {
    private let support = LocalFirstActualStoreTests()

    private func marker(_ databaseURL: URL) -> String? {
        let url = databaseURL.deletingLastPathComponent().appending(path: "metadata.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["lastScheduleRun"] as? String
    }

    private static var syncFailureScheduleSQL: String {
        let earlier = TestLocalDay.dayID(
            TestLocalDay.calendar.date(byAdding: .day, value: -3, to: Date())!
        )
        let packed = ScheduleAdvancementTests.packed(earlier)
        return ScheduleAdvancementTests.storeScheduleSQL + """
        INSERT INTO rules VALUES (
            'gym-rule', 'normal',
            '[{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":-500},{"op":"is","field":"date","value":{"start":"\(earlier)","frequency":"weekly"}}]',
            '[{"op":"link-schedule","value":"gym"}]', 'and', 0
        );
        INSERT INTO schedules VALUES ('gym', 'gym-rule', 'Gym', 0, 1, NULL, 2, 0);
        INSERT INTO schedules_next_date VALUES ('gym-next', 'gym', \(packed), 100, \(packed), 100, 0);
        INSERT INTO transactions (id, acct, date, amount, schedule) VALUES ('gym-paid', 'checking', \(packed), -500, 'gym');
        """
    }

    private func syncFailureStore() async throws -> (LocalFirstActualStoreTests.OpenedWritableStoreBundle, MerkleAwareSyncTransport) {
        let server = MerkleAwareSyncTransport()
        let bundle = try await support.makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in server },
            additionalFixtureSQL: Self.syncFailureScheduleSQL
        )
        try bundle.keychain.saveActualSyncToken("token")
        await bundle.store.syncClient.configure(LocalFirstSyncConfiguration(
            fileID: "file-1", groupID: "group-1", nodeID: "node1", encryptionKeyID: nil, encryptionContext: nil
        ))
        return (bundle, server)
    }

    private func scheduleCounts(_ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle) throws -> (rent: Int, gym: Int) {
        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        let helpers = ScheduleAdvancementTests()
        return (
            try helpers.scheduleTransactionCount("rent", url),
            try helpers.scheduleTransactionCount("gym", url)
        )
    }

    @Test func aFailedSyncAdvancesPaidSchedulesButPostsNothingThenALaterSyncPosts() async throws {
        let (bundle, server) = try await syncFailureStore()
        await server.setOnRequest { _ in throw URLError(.notConnectedToInternet) }

        await #expect(throws: (any Error).self) {
            try await bundle.store.refresh(budgetID: "group-1", serverURLString: "https://sync.example")
        }

        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        #expect(try scheduleCounts(bundle) == (0, 1))
        #expect(marker(url) == nil)
        let loaded = try await bundle.store.refreshSchedules(budgetID: "group-1", asOf: TestLocalDay.today())
        #expect(loaded.detail(id: "gym")?.status == .scheduled || loaded.detail(id: "gym")?.status == .upcoming)
        #expect(loaded.detail(id: "rent")?.status == .due)

        await server.setOnRequest { _ in }
        try await bundle.store.refresh(budgetID: "group-1", serverURLString: "https://sync.example")

        #expect(try scheduleCounts(bundle) == (1, 1))
        #expect(marker(url) == TestLocalDay.today())
    }

    @Test func aCancelledOrStaleSessionDoesNotAdvanceAfterAFailedSync() async throws {
        let (bundle, _) = try await syncFailureStore()
        let store = bundle.store
        let database = try #require(store.database)
        let before = try await database.fetchSchedules(budgetID: "group-1", today: TestLocalDay.today())

        await store.advanceSchedulesAfterSync(
            budgetID: "group-1", database: database,
            generation: store.budgetSessionGeneration + 1, syncSucceeded: false
        )
        await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await store.advanceSchedulesAfterSync(
                budgetID: "group-1", database: database,
                generation: store.budgetSessionGeneration, syncSucceeded: false
            )
        }.value

        let after = try await database.fetchSchedules(budgetID: "group-1", today: TestLocalDay.today())
        #expect(after.detail(id: "gym")?.effectiveNextDate == before.detail(id: "gym")?.effectiveNextDate)
    }
}
