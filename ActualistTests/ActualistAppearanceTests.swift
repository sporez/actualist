import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Actualist

struct ActualistAppearanceTests {
    static let lightThemes = ActualistThemeOption.allCases.filter { $0.colorScheme == .light }
    static let darkThemes = ActualistThemeOption.allCases.filter { $0.colorScheme == .dark }

    // MARK: - Scheme resolution

    @Test func fixedAppearanceIgnoresTheSystemScheme() {
        let appearance = ActualistAppearance.fixed(.emberAmber)
        #expect(appearance.option(for: .light) == .emberAmber)
        #expect(appearance.option(for: .dark) == .emberAmber)
        #expect(appearance.preferredColorScheme == .dark)
        #expect(ActualistAppearance.fixed(.coastalSageLight).preferredColorScheme == .light)
    }

    @Test func matchingSystemPicksTheSlotForEachScheme() {
        let appearance = ActualistAppearance.matchingSystem(
            SystemThemePair(light: .coastalSageLight, dark: .blueCurrent)
        )
        #expect(appearance.option(for: .light) == .coastalSageLight)
        #expect(appearance.option(for: .dark) == .blueCurrent)
        #expect(appearance.preferredColorScheme == nil)
    }

    @Test func aSlotHoldingTheWrongSchemeIsRepaired() {
        let swapped = SystemThemePair(light: .roseQuartz, dark: .coastalSageLight)
        #expect(swapped.light == .actualPurpleLight)
        #expect(swapped.dark == .actualPurple)

        let lightOnly = SystemThemePair(light: .coastalSageLight, dark: .actualPurpleLight)
        #expect(lightOnly.light == .coastalSageLight)
        #expect(lightOnly.dark == .actualPurple)

        let darkOnly = SystemThemePair(light: .whyNab, dark: .whyNab)
        #expect(darkOnly.light == .actualPurpleLight)
        #expect(darkOnly.dark == .whyNab)
    }

    @Test func seedingKeepsTheCurrentThemeInItsOwnSlot() {
        #expect(SystemThemePair.seeded(from: .coastalSageLight)
            == SystemThemePair(light: .coastalSageLight, dark: .actualPurple))
        #expect(SystemThemePair.seeded(from: .emberAmber)
            == SystemThemePair(light: .actualPurpleLight, dark: .emberAmber))
    }

    // MARK: - Persistence

    private let key = "actualist.settings.v1"

    private func load(_ json: String) throws -> AppSettings {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.Appearance.\(UUID().uuidString)"))
        defaults.set(Data(json.utf8), forKey: key)
        return AppSettingsStore(defaults: defaults).load()
    }

    @Test func aBlobWithoutSystemThemesIsAFixedTheme() throws {
        let settings = try load(#"{"theme": "emberAmber", "showTotalAssigned": true}"#)
        #expect(settings.systemThemes == nil)
        #expect(settings.appearance == .fixed(.emberAmber))
        #expect(settings.showTotalAssigned)
    }

    @Test(arguments: [
        #""systemThemes": "on""#,
        #""systemThemes": {"light": "actualPurpleLight"}"#,
        #""systemThemes": {"light": "no-such-theme", "dark": "actualPurple"}"#,
    ])
    func aMalformedPairFallsBackToTheFixedThemeAndKeepsOtherSettings(field: String) throws {
        let settings = try load(#"{"theme": "blueCurrent", "showTotalAssigned": true, \#(field)}"#)
        #expect(settings.appearance == .fixed(.blueCurrent))
        #expect(settings.showTotalAssigned)
    }

    @Test func aStoredPairWithSwappedSlotsIsRepairedOnDecode() throws {
        let settings = try load(#"{"systemThemes": {"light": "emberAmber", "dark": "coastalSageLight"}}"#)
        #expect(settings.appearance == .matchingSystem(
            SystemThemePair(light: .actualPurpleLight, dark: .actualPurple)
        ))
    }

    @Test func thePairRoundTripsAndKeepsTheFixedTheme() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.Appearance.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)
        var settings = AppSettings(theme: .roseQuartz)
        settings.systemThemes = SystemThemePair(light: .coastalSageLight, dark: .amethystHaze)
        store.save(settings)

        let loaded = store.load()
        #expect(loaded == settings)
        #expect(loaded.theme == .roseQuartz)
        #expect(loaded.appearance == .matchingSystem(
            SystemThemePair(light: .coastalSageLight, dark: .amethystHaze)
        ))
    }

    // MARK: - Adaptive palette

    private static func components(_ color: Color, _ style: UIUserInterfaceStyle) -> [CGFloat] {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha].map { ($0 * 1000).rounded() / 1000 }
    }

    private static func tokens(_ palette: ActualistThemePalette) -> [(String, Color)] {
        [
            ("background", palette.background), ("surface", palette.surface),
            ("elevatedSurface", palette.elevatedSurface), ("control", palette.control),
            ("accent", palette.accent), ("positive", palette.positive),
            ("warning", palette.warning), ("danger", palette.danger),
            ("neutral", palette.neutral), ("primaryText", palette.primaryText),
            ("secondaryText", palette.secondaryText), ("positiveForeground", palette.positiveForeground),
            ("warningForeground", palette.warningForeground), ("dangerForeground", palette.dangerForeground),
            ("neutralForeground", palette.neutralForeground), ("separator", palette.separator),
            ("chromeForeground", palette.chromeForeground),
            ("incomeTransactionAmount", palette.incomeTransactionAmount),
        ]
    }

    @Test(arguments: lightThemes, darkThemes)
    func everyAdaptiveTokenResolvesToItsSlot(light: ActualistThemeOption, dark: ActualistThemeOption) {
        let adaptive = Self.tokens(.adaptive(light: light.palette, dark: dark.palette))
        let lightTokens = Self.tokens(light.palette)
        let darkTokens = Self.tokens(dark.palette)

        for index in adaptive.indices {
            let (name, color) = adaptive[index]
            #expect(Self.components(color, .light) == Self.components(lightTokens[index].1, .light), "\(name)")
            #expect(Self.components(color, .dark) == Self.components(darkTokens[index].1, .dark), "\(name)")
        }

    }
}
