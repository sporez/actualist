import Foundation
import Testing
@testable import Actualist

struct WidgetDeepLinkTests {
    @Test func categoryLinkRoundTrips() {
        let destination = WidgetDeepLink.category(id: "category id", month: "2026-07")

        #expect(WidgetDeepLink.parse(WidgetDeepLink.url(destination)) == destination)
    }

    @Test @MainActor func routerQueuesCategoryAndSelectsBudgetTab() throws {
        let defaults = try #require(UserDefaults(suiteName: "WidgetDeepLinkTests.\(UUID().uuidString)"))
        let appState = AppState(settingsStore: AppSettingsStore(defaults: defaults))
        appState.selectedTab = .reports
        appState.accountNavigationPath = [
            ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false)
        ]
        let url = WidgetDeepLink.url(.category(id: "groceries", month: "2026-07"))

        WidgetDeepLinkRouter.handle(url, appState: appState)

        #expect(appState.selectedTab == .budget)
        #expect(appState.accountNavigationPath.isEmpty)
        #expect(appState.routeCoordinator.pendingRoute == .category(id: "groceries", month: "2026-07"))
    }

    @Test func rejectsOtherHostsAndMissingParameters() throws {
        let scheme = AppInstallationIdentity.current.urlScheme
        let otherHost = try #require(URL(string: "\(scheme)://account/one?month=2026-07"))
        let missingMonth = try #require(URL(string: "\(scheme)://category/one"))
        let invalidMonth = try #require(
            URL(string: "\(scheme)://category/one?month=not-a-month")
        )
        let otherInstallation: AppInstallationIdentity = AppInstallationIdentity.current == .production
            ? .development : .production
        let wrongInstallation = try #require(
            URL(string: "\(otherInstallation.urlScheme)://category/one?month=2026-07")
        )

        #expect(WidgetDeepLink.parse(otherHost) == nil)
        #expect(WidgetDeepLink.parse(missingMonth) == nil)
        #expect(WidgetDeepLink.parse(invalidMonth) == nil)
        #expect(WidgetDeepLink.parse(wrongInstallation) == nil)
    }
}
