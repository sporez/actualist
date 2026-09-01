import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func settingsDecodeIgnoresRetiredRestKeysAndKeepsLocalFirst() async throws {
        let data = Data("""
        {
          "backendMode": "restAPI",
          "serverURLString": "http://localhost:5007/v1",
          "localFirstServerURLString": "https://actual.example.com",
          "selectedBudgetID": "budget",
          "enabledExperimentalFeatures": ["retiredFeature"]
        }
        """.utf8)

        let settings = try JSONDecoder.actual.decode(AppSettings.self, from: data)

        #expect(settings.localFirstServerURLString == "https://actual.example.com")
        #expect(settings.selectedBudgetID == "budget")
        #expect(settings.selectedLocalFirstFileID == nil)
        #expect(settings.enabledExperimentalFeatures.isEmpty)
        #expect(settings.reportCardOrder == ReportCardOrderPreference.defaultOrder)
        #expect(settings.localFirstSyncDebug == LocalFirstSyncDebugInfo())
        #expect(!settings.greenIncomeTransactionAmountsEnabled)
        #expect(!settings.includeCarryoverCategoriesInOverspentAlerts)
        #expect(!settings.showTotalAssigned)
        #expect(!settings.showHiddenCategories)
        #expect(settings.appSwitcherPrivacyMode == .whenBackgrounded)
        #expect(settings.shortcutsEnabled)
    }

    @Test func shortcutsEnabledDefaultsOnWhenKeyIsMissingAndPersists() throws {
        let decoded = try JSONDecoder.actual.decode(AppSettings.self, from: Data("{}".utf8))
        #expect(decoded.shortcutsEnabled)

        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)
        store.save(AppSettings(shortcutsEnabled: false))
        #expect(!store.load().shortcutsEnabled)
    }

    @Test func greenIncomeTransactionAmountsPreferencePersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)
        let settings = AppSettings(greenIncomeTransactionAmountsEnabled: true)

        store.save(settings)

        #expect(store.load().greenIncomeTransactionAmountsEnabled)
    }

    @Test func showTotalAssignedPreferenceDefaultsOffAndPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)

        #expect(!AppSettings().showTotalAssigned)
        let decoded = try JSONDecoder.actual.decode(AppSettings.self, from: Data("{}".utf8))
        #expect(!decoded.showTotalAssigned)

        store.save(AppSettings(showTotalAssigned: true))

        #expect(store.load().showTotalAssigned)
    }

    @Test func showTotalAssignedPreferenceUpdatesThroughAppState() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults))

        #expect(!state.settings.showTotalAssigned)
        state.updateShowTotalAssigned(true)
        #expect(state.settings.showTotalAssigned)
        #expect(AppSettingsStore(defaults: defaults).load().showTotalAssigned)
    }

    @Test func showHiddenCategoriesPreferenceDefaultsOffAndPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)

        #expect(!AppSettings().showHiddenCategories)
        let decoded = try JSONDecoder.actual.decode(AppSettings.self, from: Data("{}".utf8))
        #expect(!decoded.showHiddenCategories)

        store.save(AppSettings(showHiddenCategories: true))

        #expect(store.load().showHiddenCategories)
    }

    @Test func showHiddenCategoriesPreferenceUpdatesThroughAppState() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults))

        #expect(!state.settings.showHiddenCategories)
        state.updateShowHiddenCategories(true)
        #expect(state.settings.showHiddenCategories)
        #expect(AppSettingsStore(defaults: defaults).load().showHiddenCategories)
    }

    @Test func carryoverOverspendingAlertPreferenceDefaultsOffAndPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)

        #expect(!AppSettings().includeCarryoverCategoriesInOverspentAlerts)

        let settings = AppSettings(includeCarryoverCategoriesInOverspentAlerts: true)
        store.save(settings)

        #expect(store.load().includeCarryoverCategoriesInOverspentAlerts)
    }

    @Test func sampleDisplayValuesPreferenceDefaultsOffAndPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)

        #expect(!AppSettings().randomizedDisplayValuesEnabled)

        let settings = AppSettings(randomizedDisplayValuesEnabled: true)
        store.save(settings)

        #expect(store.load().randomizedDisplayValuesEnabled)
    }

    @Test func hidingDeveloperModeLeavesSampleDisplayValuesEnabled() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults))

        state.updateDeveloperModeUnlocked(true)
        state.updateRandomizedDisplayValuesEnabled(true)
        state.updateDeveloperModeUnlocked(false)

        #expect(!state.settings.developerModeUnlocked)
        #expect(state.settings.randomizedDisplayValuesEnabled)
        #expect(AppSettingsStore(defaults: defaults).load().randomizedDisplayValuesEnabled)
    }

    @Test func appSwitcherPrivacyPreferenceDefaultsToBackgroundAndPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)

        #expect(AppSettings().appSwitcherPrivacyMode == .whenBackgrounded)

        let settings = AppSettings(appSwitcherPrivacyMode: .always)
        store.save(settings)

        #expect(store.load().appSwitcherPrivacyMode == .always)
    }

    @Test(arguments: [
        (AppSwitcherPrivacyMode.off, ScenePhase.active, false, false),
        (.off, .inactive, false, false),
        (.off, .background, false, false),
        (.whenBackgrounded, .active, false, false),
        (.whenBackgrounded, .inactive, false, false),
        (.whenBackgrounded, .background, false, true),
        (.whenBackgrounded, .background, true, true),
        (.always, .active, false, false),
        (.always, .inactive, false, true),
        (.always, .background, false, true),
        (.always, .inactive, true, false),
        (.always, .background, true, false)
    ])
    func appSwitcherSnapshotPolicyMatchesConfiguredLifecycleBehavior(
        mode: AppSwitcherPrivacyMode,
        phase: ScenePhase,
        isSuppressed: Bool,
        expected: Bool
    ) {
        #expect(
            AppSwitcherSnapshotPolicy.shouldCover(
                mode: mode,
                scenePhase: phase,
                isAppInitiatedSystemUISuppressed: isSuppressed
            ) == expected
        )
    }

    @Test func appSwitcherSystemUISuppressionOnlyAppliesToAlwaysModeAndClears() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults))

        state.beginAppInitiatedSystemUIPresentation()
        #expect(!state.isAppSwitcherCoverSuppressedForSystemUI)

        state.updateAppSwitcherPrivacyMode(.always)
        state.beginAppInitiatedSystemUIPresentation()
        #expect(state.isAppSwitcherCoverSuppressedForSystemUI)

        state.clearAppInitiatedSystemUIPresentationSuppression()
        #expect(!state.isAppSwitcherCoverSuppressedForSystemUI)
    }

    @Test func localFirstSyncDiagnosticsPersistInSettings() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)
        let event = LocalFirstSyncDebugEvent(
            id: UUID(),
            date: Date(timeIntervalSince1970: 1_788_000_000),
            outcome: .failed,
            pendingBefore: 5,
            uploadedCount: 0,
            downloadedCount: 0,
            pendingAfter: 5,
            message: "Network unavailable"
        )
        var settings = AppSettings()
        settings.localFirstSyncDebug = LocalFirstSyncDebugInfo(totalEventCount: 1, recentEvents: [event])

        store.save(settings)

        #expect(store.load().localFirstSyncDebug == settings.localFirstSyncDebug)
    }

    @Test func experimentalFeaturesPersistInSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)
        var settings = AppSettings()
        settings.enabledExperimentalFeatures = [.bankSync]

        store.save(settings)

        #expect(store.load().enabledExperimentalFeatures == [.bankSync])
    }

    @Test func retiredBudgetTemplateExperimentIsIgnoredWithoutDisablingBankSync() throws {
        let data = Data(#"{"enabledExperimentalFeatures":["budgetTemplates","bankSync"]}"#.utf8)

        let settings = try JSONDecoder.actual.decode(AppSettings.self, from: data)

        #expect(settings.enabledExperimentalFeatures == [.bankSync])
    }

    @Test func backgroundBankSyncAndRefreshSchedulingHonorExperimentalGate() {
        var settings = AppSettings()
        settings.simplefinBackgroundSyncEnabled = true

        #expect(!settings.isExperimentalFeatureEnabled(.bankSync))
        #expect(!settings.isBackgroundBankSyncEnabled)
        #expect(!settings.wantsBackgroundAppRefresh)

        settings.backgroundTransactionRefreshEnabled = true
        #expect(settings.wantsBackgroundAppRefresh)
        #expect(!settings.isBackgroundBankSyncEnabled)

        settings.enabledExperimentalFeatures = [.bankSync]
        #expect(settings.isExperimentalFeatureEnabled(.bankSync))
        #expect(settings.isBackgroundBankSyncEnabled)
        #expect(settings.wantsBackgroundAppRefresh)

        settings.backgroundTransactionRefreshEnabled = false
        #expect(settings.wantsBackgroundAppRefresh)

        settings.simplefinBackgroundSyncEnabled = false
        #expect(!settings.isBackgroundBankSyncEnabled)
        #expect(!settings.wantsBackgroundAppRefresh)
    }

    @Test func reportCardOrderPersistsAndRepairsMissingCards() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)
        let customOrder = Array(ReportCardOrderPreference.defaultOrder.reversed())
        let settings = AppSettings(reportCardOrder: customOrder)

        store.save(settings)

        #expect(store.load().reportCardOrder == customOrder)

        let partialData = Data(#"{"reportCardOrder":["cashFlow","unknown","cashFlow"]}"#.utf8)
        let repaired = try JSONDecoder.actual.decode(AppSettings.self, from: partialData)
        #expect(repaired.reportCardOrder.first == .cashFlow)
        #expect(repaired.reportCardOrder.count == ReportCardKind.allCases.count)
        #expect(Set(repaired.reportCardOrder) == Set(ReportCardKind.allCases))
    }
}
