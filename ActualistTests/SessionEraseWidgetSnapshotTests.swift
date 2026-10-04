import Foundation
import Testing
@testable import Actualist

/// Phase 3.3: the widget snapshot is cleared synchronously on sign-out.
@MainActor
struct SessionEraseWidgetSnapshotTests {
    private func makeSnapshot() -> WidgetSnapshot {
        WidgetSnapshot(
            schemaVersion: WidgetSnapshot.currentSchemaVersion,
            budgetID: "budget",
            budgetName: "Household",
            month: "2026-07",
            privacyEnabled: false,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            categories: []
        )
    }

    @Test func coordinatorClearSnapshotRemovesTheSavedFileImmediately() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SessionEraseWidget-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directoryURL: directory)
        try store.save(makeSnapshot())
        #expect(store.load() != nil)
        let coordinator = WidgetSnapshotCoordinator(
            snapshotStore: store, themeStore: WidgetThemeStore(defaults: nil), reloadAllTimelines: {}
        )

        coordinator.clearSnapshot()

        #expect(store.load() == nil)
    }

    @Test func disconnectAndEraseClearsTheWidgetSnapshotSynchronously() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SessionEraseWidgetApp-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = KeychainStore(service: "com.sporez.actualist.tests", account: UUID().uuidString)
        var clearCount = 0
        let state = AppState(
            settingsStore: AppSettingsStore(
                defaults: UserDefaults(suiteName: "SessionEraseWidgetTests.\(UUID().uuidString)")!
            ),
            keychain: keychain,
            localFirstStore: LocalFirstActualStore(
                keychain: keychain, fileManager: BudgetFileManager(applicationSupportURL: root)
            ),
            widgetSnapshotClearer: { clearCount += 1 }
        )

        state.disconnectAndEraseLocalData()

        #expect(clearCount == 1)
    }
}
