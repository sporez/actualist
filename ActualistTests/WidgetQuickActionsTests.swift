import Foundation
import Testing
@testable import Actualist

struct WidgetQuickActionsTests {
    @Test func normalizationPreservesOrderAndFillsFourUniqueSlots() {
        #expect(WidgetQuickActions([.reports, .reports, .addIncome]).actions == [.reports, .addIncome, .addExpense, .budget])
        #expect(WidgetQuickActions([]).actions == WidgetQuickActions.defaults)
        #expect(WidgetQuickActions(WidgetQuickAction.allCases).actions.count == WidgetQuickActions.capacity)
    }

    @Test func independentWidgetConfigurationsKeepTheirOwnOrder() {
        let first = WidgetQuickActions([.rules, .templates, .history, .addIncome])
        let second = WidgetQuickActions([.accounts, .reports, .spending, .budget])
        #expect(first.actions == [.rules, .templates, .history, .addIncome])
        #expect(second.actions == [.accounts, .reports, .spending, .budget])
        #expect(WidgetQuickActions(Array(first.actions.reversed())).actions == [.addIncome, .history, .templates, .rules])
    }

    @Test func nativePickerCatalogSearchMatchesTitlesDetailsAndGroupNames() {
        #expect(Set(WidgetQuickAction.matching()) == Set(WidgetQuickAction.allCases))
        #expect(WidgetQuickAction.matching("  INCOME  ") == [.addIncome])
        #expect(WidgetQuickAction.matching("Transactions").contains(.rules))
        #expect(WidgetQuickAction.matching("net worth") == [.reports])
        #expect(WidgetQuickAction.matching("nothing matches this").isEmpty)
    }

    @Test(arguments: WidgetQuickAction.allCases)
    func everyActionLinkRoundTrips(action: WidgetQuickAction) {
        #expect(WidgetDeepLink.parse(WidgetDeepLink.url(.quickAction(action))) == .quickAction(action))
        #expect(!action.title.isEmpty)
        #expect(!action.symbol.isEmpty)
    }

    @Test(arguments: [
        "com.sporez.actualist://action/unknown",
        "com.sporez.actualist://action",
        "com.sporez.actualist://action/budget/extra",
        "com.sporez.actualist://action/budget?payload=anything",
        "com.sporez.actualist://action/budget#extra",
        "https://action/budget"
    ])
    func malformedActionLinksAreIgnored(raw: String) throws {
        #expect(WidgetDeepLink.parse(try #require(URL(string: raw))) == nil)
    }
}

@MainActor
struct WidgetQuickActionRouteTests {
    @Test func editorRoutesOnlyPrefillDirection() {
        #expect(WidgetQuickActionRoute(action: .addExpense).route == .newTransaction(ShortcutEditorPrefill(direction: .spend)))
        #expect(WidgetQuickActionRoute(action: .addIncome).route == .newTransaction(ShortcutEditorPrefill(direction: .inflow)))
        #expect(WidgetQuickActionRoute(action: .addIncome).tab == .spending)
    }

    @Test func screenAndSettingsRoutesTargetTheirNamedDestination() {
        let settings: [(WidgetQuickAction, SettingsPage)] = [
            (.templates, .templates), (.payees, .payees), (.rules, .rules), (.bankSync, .bankSync),
            (.reportOrder, .reports), (.appearance, .appearance),
            (.privacy, .privacy), (.connection, .connection), (.budgetData, .budgetData),
            (.advanced, .advanced), (.support, .support)
        ]
        for (action, page) in settings {
            let destination = WidgetQuickActionRoute(action: action)
            #expect(destination.route == .settings)
            #expect(destination.settingsPage == page)
            #expect(destination.tab == .budget)
        }
        for (action, tab) in [(WidgetQuickAction.budget, AppTab.budget), (.accounts, .accounts), (.spending, .spending), (.reports, .reports)] {
            #expect(WidgetQuickActionRoute(action: action).route == .tab(tab))
        }
        #expect(WidgetQuickActionRoute(action: .settings).route == .settings)
        #expect(WidgetQuickActionRoute(action: .settings).settingsPage == nil)
        #expect(WidgetQuickActionRoute(action: .history).route == .history)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(WidgetQuickActionRoute(action: .uncategorized, now: now).route == .uncategorized(month: WidgetMonthID.current(now: now)))
    }

    @Test func leavingSettingsWaitsForDismissalAndLatestTapWins() throws {
        let suite = "WidgetWarmRouteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults))
        let routes = state.routeCoordinator
        routes.presentSettings()
        routes.settingsPath = [.appearance]
        WidgetDeepLinkRouter.handle(WidgetDeepLink.url(.quickAction(.addExpense)), appState: state)
        #expect(!routes.isSettingsPresented)
        #expect(routes.pendingRoute == nil)
        WidgetDeepLinkRouter.handle(WidgetDeepLink.url(.quickAction(.accounts)), appState: state)
        routes.setSettingsPresented(false)
        #expect(routes.pendingRoute == nil)
        routes.settingsDidDismiss()
        #expect(routes.pendingRoute == .tab(.accounts))
        #expect(state.selectedTab == .accounts)
        _ = routes.consume()
        routes.settingsDidDismiss()
        #expect(routes.pendingRoute == nil)
    }

    @Test func aTapDuringManualSettingsDismissalWaitsForTheAnimation() {
        let routes = AppRouteCoordinator()
        var performed = false
        routes.presentSettings()
        routes.setSettingsPresented(false)
        routes.afterDismissingSettings { performed = true }
        #expect(!performed)
        routes.settingsDidDismiss()
        #expect(performed)
        #expect(!routes.isSettingsPresented)
    }

    @Test func routingBeforeBudgetRestoreRetainsDestinationAndDoesNotDependOnShortcutsToggle() throws {
        let suite = "WidgetQuickActionRouteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults))
        state.settings.shortcutsEnabled = false
        WidgetDeepLinkRouter.handle(WidgetDeepLink.url(.quickAction(.rules)), appState: state)
        #expect(state.routeCoordinator.pendingRoute == .settings)
        #expect(state.routeCoordinator.settingsPath == [.rules])
        #expect(state.setupPhase == .needsConnection)
        WidgetDeepLinkRouter.handle(WidgetDeepLink.url(.quickAction(.appearance)), appState: state)
        #expect(state.routeCoordinator.settingsPath == [.appearance])
        WidgetDeepLinkRouter.handle(WidgetDeepLink.url(.quickAction(.accounts)), appState: state)
        #expect(state.selectedTab == .accounts)
        #expect(state.routeCoordinator.settingsPath.isEmpty)
        #expect(state.routeCoordinator.pendingRoute == .tab(.accounts))
    }
}
