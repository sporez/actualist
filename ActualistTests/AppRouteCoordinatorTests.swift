import Foundation
import Testing
@testable import Actualist

@MainActor
struct AppRouteCoordinatorTests {
    @Test func enqueueConsumeAndClear() {
        let coordinator = AppRouteCoordinator()
        #expect(coordinator.pendingRoute == nil)

        coordinator.enqueue(.tab(.spending))
        #expect(coordinator.pendingRoute == .tab(.spending))

        let consumed = coordinator.consume()
        #expect(consumed == .tab(.spending))
        #expect(coordinator.pendingRoute == nil)
        #expect(coordinator.consume() == nil)
    }

    @Test func consumeIfLeavesNonMatchingRoute() {
        let coordinator = AppRouteCoordinator()
        coordinator.enqueue(.category(id: "groceries", month: "2026-07"))

        let tab = coordinator.consume { route in
            if case .tab = route { return true }
            return false
        }
        #expect(tab == nil)
        #expect(coordinator.pendingRoute == .category(id: "groceries", month: "2026-07"))

        let category = coordinator.consume { route in
            if case .category = route { return true }
            return false
        }
        #expect(category == .category(id: "groceries", month: "2026-07"))
        #expect(coordinator.pendingRoute == nil)
    }

    @Test func notificationSpendingRouteUsesCoordinator() async {
        let defaults = UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)")
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults ?? .standard))
        state.selectedTab = .accounts
        state.accountNavigationPath = [
            ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false)
        ]

        await state.routeToSpendingFromNotification(budgetID: "budget")

        #expect(state.selectedTab == .spending)
        #expect(state.accountNavigationPath.isEmpty)
        #expect(state.routeCoordinator.pendingRoute == .tab(.spending))
    }

    @Test func routeApplicationDoesNotGuessMissingDestinations() {
        let accounts = [
            ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false)
        ]
        #expect(
            AppRouteApplication.account(from: .account(id: "checking"), in: accounts)?.id == "checking"
        )
        #expect(AppRouteApplication.account(from: .account(id: "missing"), in: accounts) == nil)
        #expect(AppRouteApplication.account(from: .tab(.accounts), in: accounts) == nil)

        let groceries = BudgetMonthCategory(
            id: "groceries",
            name: "Groceries",
            isIncome: false,
            hidden: false,
            groupID: "group",
            budgeted: 1,
            spent: 0,
            balance: 1,
            carryover: false
        )
        let applied = AppRouteApplication.category(
            from: .category(id: "groceries", month: "2026-03"),
            in: [groceries]
        )
        #expect(applied?.month == "2026-03")
        #expect(applied?.category.id == "groceries")
        #expect(
            AppRouteApplication.category(
                from: .category(id: "hidden", month: "2026-03"),
                in: [groceries]
            ) == nil
        )
        #expect(AppRouteApplication.uncategorizedMonth(from: .uncategorized(month: "2026-03")) == "2026-03")
        #expect(AppRouteApplication.uncategorizedMonth(from: .tab(.budget)) == nil)
    }

    @Test func resetDropsStaleSettingsPresentationForTheNextSession() {
        // Compact Settings is presented from BudgetView's fullScreenCover. A
        // disconnect/erase or sign-in-again removes that host without a
        // SwiftUI dismissal callback, so the coordinator must be reset at the
        // teardown boundary or the next budget session re-presents Settings.
        let coordinator = AppRouteCoordinator()
        coordinator.presentSettings(path: [.connection])
        coordinator.enqueue(.tab(.spending))
        var queuedNavigationRan = false
        coordinator.afterDismissingSettings { queuedNavigationRan = true }

        coordinator.reset()

        #expect(!coordinator.isSettingsPresented)
        #expect(coordinator.settingsPath.isEmpty)
        #expect(coordinator.pendingRoute == nil)
        #expect(!queuedNavigationRan)
        // A route enqueued after the reset still works for the new session.
        coordinator.enqueue(.tab(.spending))
        #expect(coordinator.pendingRoute == .tab(.spending))
        // A late settingsDidDismiss from the destroyed host must not fire the
        // dropped continuation or corrupt the hidden state.
        coordinator.settingsDidDismiss()
        #expect(!coordinator.isSettingsPresented)
        #expect(!queuedNavigationRan)
        coordinator.presentSettings(path: [.appearance])
        #expect(coordinator.isSettingsPresented)
        #expect(coordinator.settingsPath == [.appearance])
    }
}
