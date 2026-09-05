import Foundation
import Testing
@testable import Actualist

@MainActor
struct AdaptiveRootRoutingTests {
    @Test func budgetPayloadActivatesEvenWhenBudgetTabIsAlreadySelected() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID())"))
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults))
        state.selectedTab = .budget
        for route in [AppRoute.category(id: "groceries", month: "2026-07"), .uncategorized(month: "2026-07"), .history] {
            state.routeCoordinator.enqueue(route)
            #expect(AdaptiveRootRouting.applyPending(using: state, accounts: []) == .budget)
            #expect(state.routeCoordinator.pendingRoute == route)
        }
    }

    @Test func overviewClearsAccountPathAndAccountSelectionRestoresItOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID())"))
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults))
        let account = ActualAccount(id: "a", name: "Checking", offbudget: false, closed: false)
        AdaptiveRootRouting.activate(.account(account), using: state)
        #expect(state.accountNavigationPath == [account])
        AdaptiveRootRouting.activate(.accounts, using: state)
        #expect(state.accountNavigationPath.isEmpty)
        state.routeCoordinator.enqueue(.account(id: "a"))
        #expect(AdaptiveRootRouting.applyPending(using: state, accounts: [account]) == .account(account))
        #expect(state.accountNavigationPath == [account])
        #expect(state.routeCoordinator.pendingRoute == nil)
    }

    @Test func removedSettingsHostReleasesQueuedNavigationOnce() {
        let coordinator = AppRouteCoordinator()
        coordinator.presentSettings()
        var count = 0
        coordinator.afterDismissingSettings { count += 1 }
        coordinator.settingsHostRemoved()
        coordinator.settingsDidDismiss()
        #expect(count == 1)
        #expect(!coordinator.isSettingsPresented)
        coordinator.afterDismissingSettings { count += 1 }
        #expect(count == 2)
    }
    @Test func sidebarDoesNotPushIntoTheDepartingCompactStack() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID())"))
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults))
        let first = ActualAccount(id: "a", name: "Checking", offbudget: false, closed: false)
        let second = ActualAccount(id: "b", name: "Savings", offbudget: false, closed: false)
        state.accountNavigationPath = [first]
        AdaptiveRootRouting.activate(.account(second), using: state, mode: .sidebar)
        #expect(state.accountNavigationPath == [first])
        AdaptiveRootRouting.activate(.account(second), using: state, mode: .compact)
        #expect(state.accountNavigationPath == [second])
        AdaptiveRootRouting.activate(.accounts, using: state, mode: .sidebar)
        #expect(state.accountNavigationPath.isEmpty)
    }

}
