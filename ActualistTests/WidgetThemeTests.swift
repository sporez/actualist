import Foundation
import SwiftUI
import Testing
import WidgetKit
@testable import Actualist

struct WidgetThemeTests {
    @Test(arguments: ActualistThemeOption.allCases)
    func fullColorUsesTheAppPalette(theme: ActualistThemeOption) {
        let widget = WidgetPalette(theme: theme, renderingMode: .fullColor)
        let app = theme.palette
        #expect(widget.usesThemeColors)
        #expect(widget.primaryText == app.primaryText)
        #expect(widget.secondaryText == app.secondaryText)
        #expect(widget.accent == app.accent)
        #expect(widget.color(.positive) == app.positive)
        #expect(widget.color(.negative) == app.danger)
        #expect(widget.color(.zero) == app.secondaryText)
    }

    @Test func systemRenderingUsesSemanticColorsForBothLightAndDarkThemes() {
        for theme in [ActualistThemeOption.coastalSageLight, .blueCurrent] {
            for mode in [WidgetRenderingMode.accented, .vibrant] {
                let widget = WidgetPalette(theme: theme, renderingMode: mode)
                #expect(!widget.usesThemeColors)
                #expect(widget.primaryText == .primary)
                #expect(widget.secondaryText == .secondary)
                #expect(widget.accent == .primary)
                #expect(widget.color(.positive) == .primary)
                #expect(widget.color(.negative) == .primary)
            }
        }
    }

    @Test func themePersistsAcrossReadersAndOnlyChangesRequestRefresh() throws {
        let suite = "WidgetThemeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let writer = WidgetThemeStore(defaults: defaults)
        let reader = WidgetThemeStore(defaults: UserDefaults(suiteName: suite))
        #expect(reader.load() == .actualPurple)
        for theme in ActualistThemeOption.allCases {
            #expect(writer.saveIfChanged(theme))
            #expect(reader.load() == theme)
            #expect(!writer.saveIfChanged(theme))
        }
        #expect(defaults.persistentDomain(forName: suite)?.count == 1)
    }

    @Test func missingOrUnknownPreferenceUsesDefaultAndCanBeRepaired() throws {
        let unavailable = WidgetThemeStore(defaults: nil)
        #expect(unavailable.load() == .actualPurple)
        #expect(!unavailable.saveIfChanged(.blueCurrent))
        let suite = "WidgetThemeFallbackTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("future-theme", forKey: "widgetTheme")
        let store = WidgetThemeStore(defaults: defaults)
        #expect(store.load() == .actualPurple)
        #expect(store.saveIfChanged(.actualPurple))
        #expect(!store.saveIfChanged(.actualPurple))
    }

    @Test @MainActor func appearancePublishesWithoutABudgetAndRearmsAfterChanges() async throws {
        let suite = "WidgetThemeObservationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults))
        let store = WidgetThemeStore(defaults: defaults)
        var refreshCount = 0
        let publisher = WidgetSnapshotCoordinator(
            themeStore: store, reloadAllTimelines: { refreshCount += 1 }
        )
        publisher.configure(appState: state, snapshotStore: WidgetSnapshotStore(directoryURL: nil))
        #expect(state.settings.selectedBudgetID == nil)
        #expect(refreshCount == 1)
        for (offset, theme) in [ActualistThemeOption.blueCurrent, .coastalSageLight, .emberAmber].enumerated() {
            state.settings.theme = theme
            for _ in 0..<100 where refreshCount < offset + 2 { await Task.yield() }
            #expect(store.load() == theme)
            #expect(refreshCount == offset + 2)
        }
        state.settings.randomizedDisplayValuesEnabled.toggle()
        for _ in 0..<20 { await Task.yield() }
        #expect(refreshCount == 4)
        #expect(store.load() == .emberAmber)
    }
}
