import Foundation

@MainActor
struct BackgroundRefreshDebugRecorder {
    private let settingsStore: AppSettingsStore
    private let now: @MainActor () -> Date
    private let makeID: @MainActor () -> UUID

    init(
        settingsStore: AppSettingsStore,
        now: @escaping @MainActor () -> Date = Date.init,
        makeID: @escaping @MainActor () -> UUID = UUID.init
    ) {
        self.settingsStore = settingsStore
        self.now = now
        self.makeID = makeID
    }

    func recordScheduleAttempt(
        succeeded: Bool,
        earliestBeginDate: Date?,
        message: String,
        in settings: inout AppSettings
    ) {
        let attempt = BackgroundRefreshScheduleAttempt(
            id: makeID(),
            date: now(),
            earliestBeginDate: earliestBeginDate,
            succeeded: succeeded,
            message: message
        )
        settings.backgroundRefreshDebug.totalScheduleAttemptCount += 1
        settings.backgroundRefreshDebug.recentScheduleAttempts.insert(attempt, at: 0)
        settings.backgroundRefreshDebug.recentScheduleAttempts = Array(
            settings.backgroundRefreshDebug.recentScheduleAttempts.prefix(20)
        )
        settingsStore.save(settings)
    }

    @discardableResult
    func beginRun(in settings: inout AppSettings) -> UUID {
        let runID = makeID()
        let run = BackgroundRefreshDebugRun(
            id: runID,
            wakeDate: now(),
            completionDate: nil,
            succeeded: nil,
            message: "Started"
        )
        settings.backgroundRefreshDebug.totalWakeCount += 1
        settings.backgroundRefreshDebug.recentRuns.insert(run, at: 0)
        settings.backgroundRefreshDebug.recentRuns = Array(
            settings.backgroundRefreshDebug.recentRuns.prefix(20)
        )
        settingsStore.save(settings)
        return runID
    }

    func completeRun(
        _ runID: UUID,
        succeeded: Bool,
        message: String,
        in settings: inout AppSettings
    ) {
        guard let index = settings.backgroundRefreshDebug.recentRuns.firstIndex(where: { $0.id == runID }) else {
            return
        }
        settings.backgroundRefreshDebug.recentRuns[index].completionDate = now()
        settings.backgroundRefreshDebug.recentRuns[index].succeeded = succeeded
        settings.backgroundRefreshDebug.recentRuns[index].message = message
        settingsStore.save(settings)
    }
}
