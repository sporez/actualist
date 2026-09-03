import Foundation
import Testing
@testable import Actualist

struct WidgetSnapshotStoreTests {
    @Test func roundTripsAndClearsSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WidgetSnapshotStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directoryURL: directory)
        let snapshot = makeSnapshot()

        try store.save(snapshot)

        #expect(store.load() == snapshot)
        store.clear()
        #expect(store.load() == nil)
    }

    @Test func rejectsUnknownSchemaVersion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WidgetSnapshotStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directoryURL: directory)
        var snapshot = makeSnapshot()
        snapshot.schemaVersion += 1

        try store.save(snapshot)

        #expect(store.load() == nil)
    }

    private func makeSnapshot() -> WidgetSnapshot {
        WidgetSnapshot(
            schemaVersion: WidgetSnapshot.currentSchemaVersion,
            budgetID: "budget",
            budgetName: "Household",
            month: "2026-07",
            privacyEnabled: false,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            categories: [
                WidgetCategorySnapshot(
                    id: "groceries",
                    displayName: "Groceries",
                    group: "Everyday",
                    isHidden: false,
                    availableMinorUnits: 12_345,
                    formattedAvailable: "$123.45"
                )
            ]
        )
    }
}
