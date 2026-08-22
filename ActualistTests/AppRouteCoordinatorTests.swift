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
        let defaults = try? UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)")
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
}
