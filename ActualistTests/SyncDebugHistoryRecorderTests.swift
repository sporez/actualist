import Foundation
import Testing
@testable import Actualist

/// Concurrency remediation 4.9: a burst of sync debug events saves the history
/// once, under its own key, without re-encoding the settings blob.
@MainActor
struct SyncDebugHistoryRecorderTests {
    /// Counts writes per key so a test can tell blob saves from history saves.
    private final class CountingDefaults: UserDefaults {
        private(set) var writes: [String: Int] = [:]

        override func set(_ value: Any?, forKey defaultName: String) {
            writes[defaultName, default: 0] += 1
            super.set(value, forKey: defaultName)
        }
    }

    private func makeDefaults() throws -> (CountingDefaults, String) {
        let suite = "SyncDebugHistoryRecorderTests.\(UUID().uuidString)"
        return (try #require(CountingDefaults(suiteName: suite)), suite)
    }

    private func makeEvent(_ index: Int) -> LocalFirstSyncDebugEvent {
        LocalFirstSyncDebugEvent(
            id: UUID(), date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)), outcome: .failed,
            pendingBefore: index, uploadedCount: 0, downloadedCount: 0, pendingAfter: 0, message: SafeSyncDiagnostic.genericFailure
        )
    }

    @Test func aBurstOfEventsSavesTheHistoryOnceAndNeverTheSettingsBlob() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        let state = AppState(settingsStore: settingsStore)
        _ = state.localFirstStore

        for index in 0..<10 {
            state.localFirstStore.recordSyncDebugEvent(
                outcome: .failed, pendingBefore: index, pendingAfter: 0, message: SafeSyncDiagnostic.genericFailure, endpoint: .primary
            )
        }
        #expect(state.settings.localFirstSyncDebug.totalEventCount == 10)
        state.syncDebugHistory.flush()

        #expect(defaults.writes["actualist.settings.v1", default: 0] == 0, "an event re-saved the settings blob")
        #expect(defaults.writes[AppSettingsStore.syncDebugHistoryKey, default: 0] == 1)
        let reloaded = settingsStore.load().localFirstSyncDebug
        #expect(reloaded.totalEventCount == 10)
        #expect(reloaded.recentEvents.count == 10)
    }

    @Test func theScheduledSaveWritesAfterTheQuietPeriod() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        let recorder = SyncDebugHistoryRecorder(settingsStore: settingsStore, saveDelay: .milliseconds(20))
        var history = LocalFirstSyncDebugInfo()

        for index in 0..<3 { recorder.record(makeEvent(index), in: &history) }
        await recorder.waitForPendingSave()

        #expect(defaults.writes[AppSettingsStore.syncDebugHistoryKey, default: 0] == 1)
        #expect(settingsStore.loadSyncDebugHistory() == history)
    }

    @Test func historyKeepsTheNewestFiftyEvents() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = SyncDebugHistoryRecorder(settingsStore: AppSettingsStore(defaults: defaults), saveDelay: .seconds(60))
        var history = LocalFirstSyncDebugInfo()

        for index in 0..<60 { recorder.record(makeEvent(index), in: &history) }
        recorder.flush()

        #expect(history.totalEventCount == 60)
        #expect(history.recentEvents.count == 50)
        #expect(history.recentEvents.first?.pendingBefore == 59)
    }

    @Test func legacyHistoryInTheSettingsBlobMigratesOnce() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        var legacy = AppSettings()
        legacy.localFirstSyncDebug = LocalFirstSyncDebugInfo(totalEventCount: 4, recentEvents: [makeEvent(1)])
        settingsStore.save(legacy)
        #expect(settingsStore.loadSyncDebugHistory() == nil)

        #expect(settingsStore.load().localFirstSyncDebug == legacy.localFirstSyncDebug)
        #expect(settingsStore.loadSyncDebugHistory() == legacy.localFirstSyncDebug)

        // Once migrated, the history key wins over the blob's stale copy.
        let newer = LocalFirstSyncDebugInfo(totalEventCount: 5, recentEvents: [makeEvent(2)])
        settingsStore.saveSyncDebugHistory(newer)
        #expect(settingsStore.load().localFirstSyncDebug == newer)
        #expect(defaults.writes[AppSettingsStore.syncDebugHistoryKey, default: 0] == 2)
    }
}
