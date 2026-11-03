import Foundation
import SwiftUI
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

    private func makeState(theme: ActualistThemeOption = .actualPurple) throws -> (AppState, AppSettingsStore) {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)
        store.save(AppSettings(theme: theme))
        return (AppState(settingsStore: store), store)
    }

    @Test(arguments: [
        (ActualistThemeOption.coastalSageLight, SystemThemePair(light: .coastalSageLight, dark: .actualPurple)),
        (ActualistThemeOption.emberAmber, SystemThemePair(light: .actualPurpleLight, dark: .emberAmber)),
    ])
    func turningMatchSystemOnSeedsThePairFromTheFixedTheme(
        theme: ActualistThemeOption,
        expected: SystemThemePair
    ) throws {
        let (state, store) = try makeState(theme: theme)
        defer { ActualistTheme.activate(AppSettings().appearance) }
        let before = state.themeIdentity

        state.updateMatchSystem(true, currentColorScheme: .dark)

        #expect(state.settings.appearance == .matchingSystem(expected))
        #expect(state.settings.theme == theme)
        #expect(state.themeIdentity != before)
        #expect(store.load().systemThemes == expected)
    }

    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func turningMatchSystemOffKeepsTheThemeShowing(scheme: ColorScheme) throws {
        let (state, store) = try makeState(theme: .roseQuartz)
        defer { ActualistTheme.activate(AppSettings().appearance) }
        state.updateMatchSystem(true, currentColorScheme: scheme)
        state.updateSystemTheme(.coastalSageLight)
        state.updateSystemTheme(.blueCurrent)

        state.updateMatchSystem(false, currentColorScheme: scheme)

        let expected: ActualistThemeOption = scheme == .light ? .coastalSageLight : .blueCurrent
        #expect(state.settings.appearance == .fixed(expected))
        #expect(store.load().appearance == .fixed(expected))
    }

    @Test func slotChangesPersistAndOnlyTouchTheirOwnSlot() throws {
        let (state, store) = try makeState()
        defer { ActualistTheme.activate(AppSettings().appearance) }
        state.updateMatchSystem(true, currentColorScheme: .dark)

        state.updateSystemTheme(.coastalSageLight)
        #expect(store.load().systemThemes == SystemThemePair(light: .coastalSageLight, dark: .actualPurple))

        let beforeDark = state.themeIdentity
        state.updateSystemTheme(.whyNab)
        #expect(store.load().systemThemes == SystemThemePair(light: .coastalSageLight, dark: .whyNab))
        #expect(state.themeIdentity != beforeDark)
    }

    @Test func slotChangesAndRepeatTogglesAreIgnoredWhenTheyDoNothing() throws {
        let (state, _) = try makeState(theme: .blueCurrent)
        defer { ActualistTheme.activate(AppSettings().appearance) }
        let before = state.themeIdentity

        state.updateSystemTheme(.coastalSageLight)
        state.updateMatchSystem(false, currentColorScheme: .light)

        #expect(state.settings.appearance == .fixed(.blueCurrent))
        #expect(state.themeIdentity == before)
    }

    @Test func aRelaunchKeepsMatchSystem() throws {
        let (state, store) = try makeState()
        defer { ActualistTheme.activate(AppSettings().appearance) }
        state.updateMatchSystem(true, currentColorScheme: .light)
        state.updateSystemTheme(.coastalSageLight)

        let relaunched = AppState(settingsStore: store)
        #expect(relaunched.settings.appearance == .matchingSystem(
            SystemThemePair(light: .coastalSageLight, dark: .actualPurple)
        ))
    }
}
