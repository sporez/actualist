import Foundation

/// Records sync debug events into the in-memory history immediately and saves
/// that history, under its own key, after a quiet period. A burst of events
/// (one per sync step) is one write, and none of them re-encodes the settings
/// blob.
@MainActor
final class SyncDebugHistoryRecorder {
    static let retainedEventLimit = 50

    private let settingsStore: AppSettingsStore
    private let saveDelay: Duration
    private var latest: LocalFirstSyncDebugInfo?
    private var saveTask: Task<Void, Never>?

    init(settingsStore: AppSettingsStore, saveDelay: Duration = .seconds(2)) {
        self.settingsStore = settingsStore
        self.saveDelay = saveDelay
    }

    func record(_ event: LocalFirstSyncDebugEvent, in history: inout LocalFirstSyncDebugInfo) {
        history.totalEventCount += 1
        history.recentEvents.insert(event, at: 0)
        history.recentEvents = Array(history.recentEvents.prefix(Self.retainedEventLimit))
        latest = history
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self, saveDelay] in
            do {
                try await Task.sleep(for: saveDelay)
            } catch {
                return // A newer event rescheduled the save, or flush() wrote it.
            }
            self?.flush()
        }
    }

    /// Writes any unsaved history now (called when the app leaves the foreground).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let history = latest else { return }
        latest = nil
        settingsStore.saveSyncDebugHistory(history)
    }

    /// Completes once the scheduled save has run or been superseded.
    func waitForPendingSave() async {
        await saveTask?.value
    }
}
