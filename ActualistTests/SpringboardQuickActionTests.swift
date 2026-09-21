import Foundation
import Testing
@testable import Actualist

@MainActor
struct SpringboardQuickActionTests {
    @Test func fixedActionsMatchTheExistingDefaults() {
        #expect(SpringboardQuickAction.actions == [.addExpense, .budget, .spending, .accounts])
        for action in SpringboardQuickAction.actions {
            let type = SpringboardQuickAction.type(for: action)
            #expect(SpringboardQuickAction.action(for: type) == action)
        }
    }

    @Test func unknownAndNonSpringboardTypesAreRejected() {
        #expect(SpringboardQuickAction.action(for: "com.sporez.actualist.quick-action.reports") == nil)
        #expect(SpringboardQuickAction.action(for: "com.sporez.actualist.action.budget") == nil)
    }

    @Test func appMetadataDeclaresTheFourFixedActionsInOrder() throws {
        let items = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UIApplicationShortcutItems")
                as? [[String: String]]
        )
        #expect(items.map { $0["UIApplicationShortcutItemTitle"] } == [
            "Add Expense", "Budget", "Spending", "Accounts"
        ])
        #expect(items.compactMap { $0["UIApplicationShortcutItemType"] } == SpringboardQuickAction.actions.map {
            SpringboardQuickAction.type(for: $0)
        })
    }

    @Test func actionReceivedBeforeConfigurationRoutesAfterAppStateIsAvailable() throws {
        let coordinator = SpringboardQuickActionCoordinator()
        let type = SpringboardQuickAction.type(for: .addExpense)

        #expect(coordinator.handle(type: type))
        let state = try makeAppState()
        coordinator.configure(appState: state)

        #expect(state.selectedTab == .spending)
        #expect(
            state.routeCoordinator.pendingRoute
                == .newTransaction(ShortcutEditorPrefill(direction: .spend))
        )
    }

    @Test func actionReceivedAfterConfigurationRoutesImmediately() throws {
        let coordinator = SpringboardQuickActionCoordinator()
        let state = try makeAppState()
        coordinator.configure(appState: state)

        #expect(coordinator.handle(type: SpringboardQuickAction.type(for: .accounts)))
        #expect(state.selectedTab == .accounts)
        #expect(state.routeCoordinator.pendingRoute == .tab(.accounts))
    }

    private func makeAppState() throws -> AppState {
        let suite = "SpringboardQuickActionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return AppState(settingsStore: AppSettingsStore(defaults: defaults))
    }
}
