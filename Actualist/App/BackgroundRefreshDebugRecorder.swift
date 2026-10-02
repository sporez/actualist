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
        var persisted = settingsStore.load()
        persisted.backgroundRefreshDebug.totalScheduleAttemptCount += 1
        persisted.backgroundRefreshDebug.recentScheduleAttempts.insert(attempt, at: 0)
        persisted.backgroundRefreshDebug.recentScheduleAttempts = Array(
            persisted.backgroundRefreshDebug.recentScheduleAttempts.prefix(20)
        )
        settingsStore.save(persisted)
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
        var persisted = settingsStore.load()
        persisted.backgroundRefreshDebug.totalWakeCount += 1
        persisted.backgroundRefreshDebug.recentRuns.insert(run, at: 0)
        persisted.backgroundRefreshDebug.recentRuns = Array(
            persisted.backgroundRefreshDebug.recentRuns.prefix(20)
        )
        settingsStore.save(persisted)
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
        persistRun(runID, from: settings)
    }

    func updateDetails(
        _ details: BackgroundRefreshDiagnosticDetails,
        for runID: UUID,
        in settings: inout AppSettings
    ) {
        guard let index = settings.backgroundRefreshDebug.recentRuns.firstIndex(where: { $0.id == runID }) else {
            return
        }
        settings.backgroundRefreshDebug.recentRuns[index].diagnosticDetails = details
        persistRun(runID, from: settings)
    }

    func recordPendingIDClear(
        scope: BackgroundPendingIDClearEvent.Scope,
        count: Int,
        in settings: inout AppSettings
    ) {
        let event = BackgroundPendingIDClearEvent(
            id: makeID(), date: now(), scope: scope, clearedCount: count
        )
        settings.backgroundRefreshDebug.recentPendingIDClears.insert(event, at: 0)
        settings.backgroundRefreshDebug.recentPendingIDClears = Array(
            settings.backgroundRefreshDebug.recentPendingIDClears.prefix(20)
        )
        var persisted = settingsStore.load()
        persisted.backgroundRefreshDebug.recentPendingIDClears.insert(event, at: 0)
        persisted.backgroundRefreshDebug.recentPendingIDClears = Array(
            persisted.backgroundRefreshDebug.recentPendingIDClears.prefix(20)
        )
        settingsStore.save(persisted)
    }

    private func persistRun(_ runID: UUID, from settings: AppSettings) {
        guard let run = settings.backgroundRefreshDebug.recentRuns.first(where: { $0.id == runID }) else { return }
        var persisted = settingsStore.load()
        if let index = persisted.backgroundRefreshDebug.recentRuns.firstIndex(where: { $0.id == runID }) {
            persisted.backgroundRefreshDebug.recentRuns[index] = run
        } else {
            persisted.backgroundRefreshDebug.totalWakeCount += 1
            persisted.backgroundRefreshDebug.recentRuns.insert(run, at: 0)
            persisted.backgroundRefreshDebug.recentRuns = Array(
                persisted.backgroundRefreshDebug.recentRuns.prefix(20)
            )
        }
        settingsStore.save(persisted)
    }
}
