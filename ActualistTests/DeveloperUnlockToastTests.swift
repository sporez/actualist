import Foundation
import Testing
@testable import Actualist

@MainActor
struct DeveloperUnlockToastTests {
    private func makeAppState() -> AppState {
        let defaults = UserDefaults(suiteName: "ActualistTests.DeveloperUnlockToast.\(UUID().uuidString)")!
        return AppState(
            settingsStore: AppSettingsStore(defaults: defaults),
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString,
                backend: FakeKeychainBackend()
            )
        )
    }

    @Test func replacingWithTheSameMessageKeepsTheToastVisible() async {
        let appState = makeAppState()
        let first = DeveloperUnlockToast.present("Developer mode on", on: appState, replacing: nil)
        let second = DeveloperUnlockToast.present("Developer mode on", on: appState, replacing: first)

        // The cancelled first dismiss task must have finished before asserting.
        await first.value

        #expect(appState.developerUnlockToastMessage == "Developer mode on")
        second.cancel()
        await second.value
        #expect(appState.developerUnlockToastMessage == "Developer mode on")
    }
}
