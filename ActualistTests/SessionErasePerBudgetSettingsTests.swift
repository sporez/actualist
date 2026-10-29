import Foundation
import Testing
@testable import Actualist

/// Erasing local data also forgets every budget's account order, default
/// account and group expansion, in memory and in the saved settings.
@MainActor
struct SessionErasePerBudgetSettingsTests {
    private struct Fixture {
        let state: AppState
        let settingsStore: AppSettingsStore
        let root: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SessionErasePerBudget-\(UUID().uuidString)", directoryHint: .isDirectory)
        let defaults = try #require(UserDefaults(suiteName: "SessionErasePerBudgetSettingsTests.\(UUID().uuidString)"))
        let settingsStore = AppSettingsStore(defaults: defaults)
        var seeded = AppSettings()
        seeded.accountOrderByBudgetID = ["budget-a": ["account-2", "account-1"], "budget-b": ["account-3"]]
        seeded.defaultAccountIDByBudgetID = ["budget-a": "account-1"]
        seeded.categoryGroupExpansionByBudgetID = ["budget-a": BudgetGroupExpansion(choices: ["group-1": false])]
        settingsStore.save(seeded)
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests", account: UUID().uuidString, backend: FakeKeychainBackend()
        )
        let state = AppState(
            settingsStore: settingsStore,
            keychain: keychain,
            localFirstStore: LocalFirstActualStore(
                keychain: keychain, fileManager: BudgetFileManager(applicationSupportURL: root)
            ),
            applicationBadgeUpdater: { _ in }
        )
        #expect(state.settings.accountOrderByBudgetID.count == 2)
        return Fixture(state: state, settingsStore: settingsStore, root: root)
    }

    private func expectPerBudgetSettingsCleared(_ fixture: Fixture) {
        for settings in [fixture.state.settings, fixture.settingsStore.load()] {
            #expect(settings.accountOrderByBudgetID.isEmpty)
            #expect(settings.defaultAccountIDByBudgetID.isEmpty)
            #expect(settings.categoryGroupExpansionByBudgetID.isEmpty)
        }
    }

    @Test func disconnectAndEraseForgetsPerBudgetSettings() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await fixture.state.disconnectAndEraseLocalData()

        expectPerBudgetSettingsCleared(fixture)
    }

    @Test func launchEraseForgetsPerBudgetSettings() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.state.disconnectAndEraseLocalDataBeforeFirstSession()

        expectPerBudgetSettingsCleared(fixture)
    }
}
