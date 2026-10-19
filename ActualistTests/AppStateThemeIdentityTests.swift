import Foundation
import Testing
@testable import Actualist

@MainActor
struct AppStateThemeIdentityTests {
    @Test func everyThemeChangeProducesANewIdentity() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults))
        // updateTheme also sets the app-wide palette; put the default back.
        defer { state.updateTheme(AppSettings().theme) }
        let initial = state.themeIdentity

        state.updateTheme(.actualPurpleLight)
        let light = state.themeIdentity
        #expect(light != initial)

        // Re-selecting the same theme still re-themes views built before it.
        state.updateTheme(.actualPurpleLight)
        #expect(state.themeIdentity != light)
    }
}
