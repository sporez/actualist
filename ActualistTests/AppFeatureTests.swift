import Foundation
import Testing
@testable import Actualist

@MainActor
struct AppFeatureTests {
    @Test func newTransactionNotificationCopyIsGeneric() {
        #expect(NewTransactionsNotificationCopy.title == "Actualist")
        #expect(NewTransactionsNotificationCopy.body == "New transactions found")
    }

    @Test func newTransactionNotificationCarriesPendingHighlightCountAsBadge() {
        let coordinator = NewTransactionNotificationCoordinator()
        let content = coordinator.makeContent(budgetID: "budget", badgeCount: 3)

        #expect(content.badge?.intValue == 3)
        #expect(content.userInfo["budgetID"] as? String == "budget")
    }

    @Test func pendingHighlightCountDeduplicatesTransactionIDsAcrossAccounts() {
        let coordinator = NewTransactionNotificationCoordinator()

        let count = coordinator.pendingIDCount(in: [
            "budget|checking": ["txn-1", "txn-2"],
            "budget|credit": ["txn-2", "txn-3"]
        ])

        #expect(count == 3)
    }

    @Test func budgetTemplatesRequireExperimentalFeature() {
        let state = makeAppState()

        #expect(!state.canApplyBudgetTemplates)

        state.updateExperimentalFeature(.budgetTemplates, isEnabled: true)
        #expect(state.canApplyBudgetTemplates)

        state.updateExperimentalFeature(.budgetTemplates, isEnabled: false)
        #expect(!state.canApplyBudgetTemplates)
    }

    @Test func transactionNotificationRoutingSelectsSpending() async {
        let state = makeAppState()
        state.selectedTab = .accounts
        state.accountNavigationPath = [
            ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false)
        ]

        await state.routeToSpendingFromNotification(budgetID: "budget")

        #expect(state.selectedTab == .spending)
        #expect(state.accountNavigationPath.isEmpty)
    }

    @Test func clearingBudgetPendingNewTransactionsClearsEveryAccountInBudgetOnlyAndUpdatesBadge() {
        var badgeCounts: [Int] = []
        let state = makeAppState { badgeCounts.append($0) }
        state.settings.pendingNewTransactionIDsByAccount = [
            "budget|checking": ["txn-1"],
            "budget|credit": ["txn-2"],
            "other|checking": ["txn-3"]
        ]

        state.clearPendingNewTransactionIDs(budgetID: "budget")

        #expect(state.settings.pendingNewTransactionIDsByAccount["budget|checking"] == nil)
        #expect(state.settings.pendingNewTransactionIDsByAccount["budget|credit"] == nil)
        #expect(state.settings.pendingNewTransactionIDsByAccount["other|checking"] == ["txn-3"])
        #expect(badgeCounts == [1])
    }

    @Test func clearingLastAccountHighlightClearsApplicationBadge() {
        var badgeCounts: [Int] = []
        let state = makeAppState { badgeCounts.append($0) }
        state.settings.pendingNewTransactionIDsByAccount = [
            "budget|checking": ["txn-1", "txn-2"]
        ]

        state.clearPendingNewTransactionIDs(budgetID: "budget", accountID: "checking")

        #expect(state.settings.pendingNewTransactionIDsByAccount.isEmpty)
        #expect(badgeCounts == [0])
    }

    @Test func preparingEnabledBackgroundNotificationsRefreshesBadgeAuthorizationAndCount() async {
        var authorizationRequestCount = 0
        var badgeCounts: [Int] = []
        let state = makeAppState(
            notificationAuthorizationRequester: {
                authorizationRequestCount += 1
                return true
            },
            applicationBadgeUpdater: { badgeCounts.append($0) }
        )
        state.settings.backgroundTransactionRefreshEnabled = true
        state.settings.pendingNewTransactionIDsByAccount = [
            "budget|checking": ["txn-1", "txn-2"]
        ]

        await state.prepareBackgroundTransactionNotifications()

        #expect(authorizationRequestCount == 1)
        #expect(badgeCounts == [2])
    }

    @Test func defaultAccountIDRoundTripsPerBudget() {
        let state = makeAppState()

        #expect(state.defaultAccountID(forBudgetID: "budget-a") == nil)

        state.setDefaultAccountID("checking", budgetID: "budget-a")
        #expect(state.defaultAccountID(forBudgetID: "budget-a") == "checking")

        state.setDefaultAccountID("savings", budgetID: "budget-b")
        #expect(state.defaultAccountID(forBudgetID: "budget-a") == "checking")
        #expect(state.defaultAccountID(forBudgetID: "budget-b") == "savings")

        state.setDefaultAccountID(nil, budgetID: "budget-a")
        #expect(state.defaultAccountID(forBudgetID: "budget-a") == nil)
        #expect(state.defaultAccountID(forBudgetID: "budget-b") == "savings")
    }

    private func makeAppState(
        notificationAuthorizationRequester: @escaping @MainActor () async throws -> Bool = {
            true
        },
        applicationBadgeUpdater: @escaping @MainActor (Int) -> Void = { _ in }
    ) -> AppState {
        let defaultsName = "ActualistTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        return AppState(
            settingsStore: AppSettingsStore(defaults: defaults),
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString
            ),
            notificationAuthorizationRequester: notificationAuthorizationRequester,
            applicationBadgeUpdater: applicationBadgeUpdater
        )
    }
}
