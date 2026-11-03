import Foundation
import Observation
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
        #expect(reader.load() == .fixed(.actualPurple))
        for theme in ActualistThemeOption.allCases {
            #expect(writer.saveIfChanged(.fixed(theme)))
            #expect(reader.load() == .fixed(theme))
            #expect(!writer.saveIfChanged(.fixed(theme)))
        }
        #expect(defaults.persistentDomain(forName: suite)?.count == 1)
    }

    @Test func missingOrUnknownPreferenceUsesDefaultAndCanBeRepaired() throws {
        let unavailable = WidgetThemeStore(defaults: nil)
        #expect(unavailable.load() == .fixed(.actualPurple))
        #expect(!unavailable.saveIfChanged(.fixed(.blueCurrent)))
        let suite = "WidgetThemeFallbackTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("future-theme", forKey: "widgetTheme")
        let store = WidgetThemeStore(defaults: defaults)
        #expect(store.load() == .fixed(.actualPurple))
        #expect(store.saveIfChanged(.fixed(.actualPurple)))
        #expect(!store.saveIfChanged(.fixed(.actualPurple)))
    }

    @Test @MainActor func appearancePublishesWithoutABudgetAndRearmsAfterChanges() async throws {
        let suite = "WidgetThemeObservationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults))
        let store = WidgetThemeStore(defaults: defaults)
        var refreshCount = 0
        var expectedRefresh: TestLatch?
        let publisher = WidgetSnapshotCoordinator(
            themeStore: store, reloadAllTimelines: {
                refreshCount += 1
                expectedRefresh?.trip()
            }
        )
        publisher.configure(appState: state, snapshotStore: WidgetSnapshotStore(directoryURL: nil))
        #expect(state.settings.selectedBudgetID == nil)
        #expect(refreshCount == 1)
        for (offset, theme) in [ActualistThemeOption.blueCurrent, .coastalSageLight, .emberAmber].enumerated() {
            let refresh = TestLatch()
            expectedRefresh = refresh
            state.settings.theme = theme
            await refresh.wait()
            #expect(store.load() == .fixed(theme))
            #expect(refreshCount == offset + 2)
        }
        expectedRefresh = nil
        let randomizationChanged = TestLatch()
        withObservationTracking {
            _ = state.settings.randomizedDisplayValuesEnabled
        } onChange: {
            Task { @MainActor in randomizationChanged.trip() }
        }
        state.settings.randomizedDisplayValuesEnabled.toggle()
        await randomizationChanged.wait()
        #expect(refreshCount == 4)
        #expect(store.load() == .fixed(.emberAmber))
    }

    @Test func thePairRoundTripsAndOnlyChangesRequestRefresh() throws {
        let suite = "WidgetThemePairTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let writer = WidgetThemeStore(defaults: defaults)
        let reader = WidgetThemeStore(defaults: UserDefaults(suiteName: suite))
        let pair = SystemThemePair(light: .coastalSageLight, dark: .roseQuartz)

        #expect(writer.saveIfChanged(.matchingSystem(pair)))
        #expect(reader.load() == .matchingSystem(pair))
        #expect(!writer.saveIfChanged(.matchingSystem(pair)))

        let darkChanged = SystemThemePair(light: .coastalSageLight, dark: .whyNab)
        #expect(writer.saveIfChanged(.matchingSystem(darkChanged)))
        #expect(reader.load() == .matchingSystem(darkChanged))

        // Turning Match System off drops the pair even when the fixed theme is unchanged.
        #expect(writer.saveIfChanged(.fixed(.actualPurple)))
        #expect(reader.load() == .fixed(.actualPurple))
        #expect(!writer.saveIfChanged(.fixed(.actualPurple)))
    }

    @Test func anOlderStoreWithOnlyTheFixedThemeLoadsFixed() throws {
        let suite = "WidgetThemeLegacyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("blueCurrent", forKey: "widgetTheme")
        #expect(WidgetThemeStore(defaults: defaults).load() == .fixed(.blueCurrent))

        defaults.set(Data("not json".utf8), forKey: "widgetSystemThemes")
        #expect(WidgetThemeStore(defaults: defaults).load() == .fixed(.blueCurrent))
    }

    @Test @MainActor func matchSystemPublishesThePairAndSlotChanges() async throws {
        let suite = "WidgetThemePairObservationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults))
        let store = WidgetThemeStore(defaults: defaults)
        var refreshCount = 0
        var expectedRefresh: TestLatch?
        let publisher = WidgetSnapshotCoordinator(
            themeStore: store, reloadAllTimelines: {
                refreshCount += 1
                expectedRefresh?.trip()
            }
        )
        publisher.configure(appState: state, snapshotStore: WidgetSnapshotStore(directoryURL: nil))
        #expect(refreshCount == 1)

        let pairs = [
            SystemThemePair(light: .actualPurpleLight, dark: .actualPurple),
            SystemThemePair(light: .coastalSageLight, dark: .actualPurple),
        ]
        for (offset, pair) in pairs.enumerated() {
            let refresh = TestLatch()
            expectedRefresh = refresh
            state.settings.systemThemes = pair
            await refresh.wait()
            #expect(store.load() == .matchingSystem(pair))
            #expect(refreshCount == offset + 2)
        }
        expectedRefresh = nil
    }
}
