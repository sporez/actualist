import Foundation
import Testing
@testable import Actualist

@MainActor
struct BackgroundRefreshDebugRecorderTests {
    @Test func runRecordingUsesDeterministicValuesAndPersistsCompletion() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        var settings = AppSettings()

        let runID = fixture.recorder.beginRun(in: &settings)
        fixture.recorder.completeRun(
            runID,
            succeeded: true,
            message: "Synced",
            in: &settings
        )

        let run = try #require(settings.backgroundRefreshDebug.recentRuns.first)
        #expect(run.id == fixture.id)
        #expect(run.wakeDate == fixture.date)
        #expect(run.completionDate == fixture.date)
        #expect(run.succeeded == true)
        #expect(run.message == "Synced")
        #expect(fixture.store.load().backgroundRefreshDebug == settings.backgroundRefreshDebug)
    }

    @Test func recorderRetainsNewestTwentyRunsAndScheduleAttempts() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        var settings = AppSettings()

        for index in 0..<21 {
            _ = fixture.recorder.beginRun(in: &settings)
            fixture.recorder.recordScheduleAttempt(
                succeeded: true,
                earliestBeginDate: nil,
                message: "Attempt \(index)",
                in: &settings
            )
        }

        #expect(settings.backgroundRefreshDebug.totalWakeCount == 21)
        #expect(settings.backgroundRefreshDebug.recentRuns.count == 20)
        #expect(settings.backgroundRefreshDebug.totalScheduleAttemptCount == 21)
        #expect(settings.backgroundRefreshDebug.recentScheduleAttempts.count == 20)
        #expect(settings.backgroundRefreshDebug.recentScheduleAttempts.first?.message == "Attempt 20")
    }

    @Test func completingUnknownRunIsNoOp() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        var settings = AppSettings()

        fixture.recorder.completeRun(
            UUID(),
            succeeded: false,
            message: "Unknown",
            in: &settings
        )

        #expect(settings.backgroundRefreshDebug == BackgroundRefreshDebugInfo())
    }

    private static func makeFixture() throws -> RecorderFixture {
        let suiteName = "BackgroundRefreshDebugRecorderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let store = AppSettingsStore(defaults: defaults)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        return RecorderFixture(
            suiteName: suiteName,
            defaults: defaults,
            store: store,
            date: date,
            id: id,
            recorder: BackgroundRefreshDebugRecorder(
                settingsStore: store,
                now: { date },
                makeID: { id }
            )
        )
    }
}

private struct RecorderFixture {
    let suiteName: String
    let defaults: UserDefaults
    let store: AppSettingsStore
    let date: Date
    let id: UUID
    let recorder: BackgroundRefreshDebugRecorder
}
