import Foundation
import Testing
@testable import Actualist

struct SharedTransactionLinkTests {
    private let id = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"

    @Test func universalLinkKeepsTheIDInTheFragmentAndRoundTrips() throws {
        let link = try #require(SharedTransactionLink(transactionID: id))
        let production = link.url(.universal, installation: .production)
        let development = link.url(.universal, installation: .development)

        #expect(production.absoluteString == "https://actualist.app/t#\(id)")
        #expect(development.absoluteString == "https://actualist.app/dev/t#\(id)")
        #expect(production.query == nil)
        #expect(SharedTransactionLink.parse(production, installation: .production) == link)
        #expect(SharedTransactionLink.parse(development, installation: .development) == link)
    }

    @Test func appSchemeLinkRoundTripsForItsOwnInstallation() throws {
        let link = try #require(SharedTransactionLink(transactionID: id))
        let production = link.url(.appScheme, installation: .production)

        #expect(production.absoluteString == "com.sporez.actualist://transaction#\(id)")
        #expect(SharedTransactionLink.parse(production, installation: .production) == link)
        #expect(SharedTransactionLink.parse(link.url(.appScheme, installation: .development), installation: .development) == link)
    }

    @Test func installsNeverClaimEachOthersLinks() throws {
        let link = try #require(SharedTransactionLink(transactionID: id))

        #expect(SharedTransactionLink.parse(link.url(.universal, installation: .development), installation: .production) == nil)
        #expect(SharedTransactionLink.parse(link.url(.universal, installation: .production), installation: .development) == nil)
        #expect(SharedTransactionLink.parse(link.url(.appScheme, installation: .development), installation: .production) == nil)
    }

    @Test(arguments: [
        "https://actualist.app/t",
        "https://actualist.app/t#",
        "https://actualist.app/t/#abc",
        "https://actualist.app/x#abc",
        "https://www.actualist.app/t#abc",
        "https://example.com/t#abc",
        "http://actualist.app/t#abc",
        "https://actualist.app:8443/t#abc",
        "https://actualist.app/t?budget=one#abc",
        "https://actualist.app/t#abc/def",
        "https://actualist.app/t#abc%2Fdef",
        "https://actualist.app/t#a%20b",
        "com.sporez.actualist://transaction/abc#abc",
        "com.sporez.actualist://account/abc",
        "com.sporez.actualist://transaction?id=abc",
    ])
    func rejectsMalformedLinks(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(SharedTransactionLink.parse(url, installation: .production) == nil)
    }

    @Test func percentEncodingIsDecodedOnce() throws {
        let url = try #require(URL(string: "https://actualist.app/t#ab%63"))
        #expect(SharedTransactionLink.parse(url, installation: .production)?.transactionID == "abc")
    }

    @Test func rejectsOverlongIDs() {
        #expect(SharedTransactionLink(transactionID: String(repeating: "a", count: 128)) != nil)
        #expect(SharedTransactionLink(transactionID: String(repeating: "a", count: 129)) == nil)
    }

    @Test @MainActor func routerQueuesTheTransactionWithoutChangingTabs() throws {
        let appState = try makeAppState()
        appState.selectedTab = .reports
        let link = try #require(SharedTransactionLink(transactionID: id))

        AppDeepLinkRouter.handle(link.url(.universal), appState: appState)

        #expect(appState.selectedTab == .reports)
        #expect(appState.routeCoordinator.pendingRoute == .sharedTransaction(id: id))
    }

    @Test @MainActor func routerWaitsForSettingsToCloseFirst() throws {
        let appState = try makeAppState()
        appState.routeCoordinator.presentSettings()
        let link = try #require(SharedTransactionLink(transactionID: id))

        AppDeepLinkRouter.handle(link.url(.appScheme), appState: appState)
        #expect(appState.routeCoordinator.pendingRoute == nil)
        #expect(!appState.routeCoordinator.isSettingsPresented)

        appState.routeCoordinator.settingsDidDismiss()
        #expect(appState.routeCoordinator.pendingRoute == .sharedTransaction(id: id))
    }

    @Test @MainActor func widgetLinksStillRouteAsBefore() throws {
        let appState = try makeAppState()

        AppDeepLinkRouter.handle(WidgetDeepLink.url(.account(id: "checking")), appState: appState)

        #expect(appState.selectedTab == .accounts)
        #expect(appState.routeCoordinator.pendingRoute == .account(id: "checking"))
    }

    @MainActor
    private func makeAppState() throws -> AppState {
        let defaults = try #require(UserDefaults(suiteName: "SharedTransactionLinkTests.\(UUID().uuidString)"))
        return AppState(settingsStore: AppSettingsStore(defaults: defaults))
    }
}
