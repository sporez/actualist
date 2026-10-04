import Foundation
import Testing
@testable import Actualist

struct AppSettingsLenientDecodingTests {
    private let key = "actualist.settings.v1"

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ActualistTests.Lenient.\(UUID().uuidString)"))
    }

    @Test func oneBadFieldKeepsServerAndBudgetSelection() throws {
        let defaults = try makeDefaults()
        let json = """
        {
          "localFirstServerURLString": "https://sync.example",
          "selectedBudgetID": "group-1",
          "selectedLocalFirstFileID": "file-1",
          "theme": "no-such-theme",
          "backgroundRefreshDebug": "not an object",
          "shortcutsEnabled": "yes",
          "showTotalAssigned": true
        }
        """
        defaults.set(Data(json.utf8), forKey: key)

        let settings = AppSettingsStore(defaults: defaults).load()

        #expect(settings.localFirstServerURLString == "https://sync.example")
        #expect(settings.selectedBudgetID == "group-1")
        #expect(settings.selectedLocalFirstFileID == "file-1")
        #expect(settings.theme == .actualPurple)
        #expect(settings.backgroundRefreshDebug == BackgroundRefreshDebugInfo())
        #expect(settings.shortcutsEnabled)
        #expect(settings.showTotalAssigned)
        #expect(defaults.data(forKey: AppSettingsStore.corruptBackupKey) == nil)
    }

    @Test func malformedSyncDebugBlobDoesNotResetSettings() throws {
        let defaults = try makeDefaults()
        let json = """
        {
          "localFirstServerURLString": "https://sync.example",
          "selectedBudgetID": "group-1",
          "localFirstSyncDebug": {"totalEventCount": 1, "recentEvents": [{"id": "bad"}]}
        }
        """
        defaults.set(Data(json.utf8), forKey: key)

        let settings = AppSettingsStore(defaults: defaults).load()

        #expect(settings.localFirstServerURLString == "https://sync.example")
        #expect(settings.selectedBudgetID == "group-1")
        #expect(settings.localFirstSyncDebug == LocalFirstSyncDebugInfo())
    }

    @Test func nonJSONBlobIsBackedUpAndNotOverwrittenByLaterCorruption() throws {
        let defaults = try makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        let first = Data("not json at all".utf8)
        defaults.set(first, forKey: key)

        #expect(store.load() == AppSettings())
        #expect(defaults.data(forKey: AppSettingsStore.corruptBackupKey) == first)

        store.save(AppSettings(localFirstServerURLString: "https://new.example"))
        #expect(defaults.data(forKey: AppSettingsStore.corruptBackupKey) == first)

        defaults.set(Data("second corruption".utf8), forKey: key)
        _ = store.load()
        #expect(defaults.data(forKey: AppSettingsStore.corruptBackupKey) == first)
    }
}
