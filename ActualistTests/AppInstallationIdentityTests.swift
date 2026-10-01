import Foundation
import Security
import Testing
@testable import Actualist

@MainActor
struct AppInstallationIdentityTests {
    @Test func productionIdentifiersPreserveInstalledDataAndLinks() {
        let identity = AppInstallationIdentity.production
        #expect(identity.rawValue == "com.sporez.actualist")
        #expect(identity.appGroupIdentifier == "group.com.sporez.actualist")
        #expect(identity.keychainService == "com.sporez.actualist")
        #expect(identity.urlScheme == "com.sporez.actualist")
        #expect(identity.backgroundTaskIdentifier == "com.sporez.actualist.transactions.refresh")
        #expect(identity.quickActionPrefix == "com.sporez.actualist.quick-action.")
        #expect(identity.widgetBundleIdentifier == "com.sporez.actualist.widgets")
    }

    @Test func developmentIdentifiersAreDisjoint() {
        let production = AppInstallationIdentity.production
        let development = AppInstallationIdentity.development
        #expect(development.rawValue == "com.sporez.actualist.dev")
        #expect(development.appGroupIdentifier != production.appGroupIdentifier)
        #expect(development.keychainService != production.keychainService)
        #expect(development.urlScheme != production.urlScheme)
        #expect(development.backgroundTaskIdentifier != production.backgroundTaskIdentifier)
        #expect(development.quickActionPrefix != production.quickActionPrefix)
        #expect(development.widgetBundleIdentifier != production.widgetBundleIdentifier)
    }

    @Test(arguments: AppInstallationIdentity.allCases)
    func appAndWidgetResolveTheSameInstallation(identity: AppInstallationIdentity) {
        #expect(AppInstallationIdentity.resolve(
            appIdentifier: identity.rawValue, bundleIdentifier: identity.rawValue
        ) == identity)
        #expect(AppInstallationIdentity.resolve(
            appIdentifier: identity.rawValue, bundleIdentifier: identity.widgetBundleIdentifier
        ) == identity)
        let other: AppInstallationIdentity = identity == .production ? .development : .production
        #expect(AppInstallationIdentity.resolve(
            appIdentifier: identity.rawValue, bundleIdentifier: other.rawValue
        ) == nil)
        #expect(AppInstallationIdentity.resolve(
            appIdentifier: identity.rawValue, bundleIdentifier: other.widgetBundleIdentifier
        ) == nil)
    }

    @Test func missingOrInvalidConfigurationCannotUseProductionResources() {
        #expect(AppInstallationIdentity.resolve(appIdentifier: nil, bundleIdentifier: nil) == nil)
        #expect(AppInstallationIdentity.resolve(
            appIdentifier: nil, bundleIdentifier: "com.sporez.actualist.dev"
        ) == nil)
        #expect(AppInstallationIdentity.resolve(
            appIdentifier: "$(ACTUALIST_APP_IDENTIFIER)", bundleIdentifier: "com.sporez.actualist.dev"
        ) == nil)
        #expect(AppInstallationIdentity.resolve(
            appIdentifier: "com.sporez.actualist.dev", bundleIdentifier: nil
        ) == nil)
    }

    @Test func runningAppMetadataMatchesEveryIdentityConsumer() throws {
        let identity = AppInstallationIdentity.current
        #expect(Bundle.main.bundleIdentifier == identity.rawValue)
        #expect(KeychainStore.actualist.service == identity.keychainService)
        #expect(WidgetAppGroup.identifier == identity.appGroupIdentifier)
        #expect(WidgetDeepLink.scheme == identity.urlScheme)
        #expect(ActualOpenIDAuthenticationCoordinator.callbackScheme == identity.urlScheme)
        #expect(BackgroundTransactionRefreshCoordinator.taskIdentifier == identity.backgroundTaskIdentifier)
        #expect(SpringboardQuickAction.typePrefix == identity.quickActionPrefix)
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        #expect(permitted == [identity.backgroundTaskIdentifier])
        let urlTypes = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        #expect(urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] } == [identity.urlScheme])
    }

    @Test func developmentCredentialRemovalAndPromotionLeaveProductionUntouched() throws {
        // Deliberately share a fake to exercise service-level isolation within one MainActor test.
        let backend = FakeKeychainBackend()
        let production = KeychainStore(
            service: AppInstallationIdentity.production.keychainService,
            account: "actual-sync-token", backend: backend
        )
        let development = KeychainStore(
            service: AppInstallationIdentity.development.keychainService,
            account: "actual-sync-token", backend: backend
        )
        let key = Data(repeating: 1, count: 32)
        try production.saveActualSyncToken("synthetic-production")
        try production.saveLocalFirstEncryptionKey(key, fileID: "fixture", keyID: "fixture-key")
        #expect(try development.readActualSyncToken() == nil)
        #expect(try development.readLocalFirstEncryptionKey(fileID: "fixture", keyID: "fixture-key") == nil)
        try development.saveActualSyncToken("synthetic-development")
        try development.saveLocalFirstEncryptionKey(key, fileID: "fixture", keyID: "fixture-key")
        try development.promoteAllItemsForBackgroundRefresh()
        try development.removeActualSyncToken()
        try development.removeAllLocalFirstEncryptionKeys()
        #expect(try production.readActualSyncToken() == "synthetic-production")
        #expect(try production.readLocalFirstEncryptionKey(fileID: "fixture", keyID: "fixture-key") == key)
        #expect(backend.storedItemAttributes(service: development.service).isEmpty)
        for item in backend.storedItemAttributes(service: production.service) {
            #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        }
    }
}
