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

    @Test func bankSyncRequiresExperimentalFeatureAndDoesNotClearAlerts() {
        let state = makeAppState()
        state.settings.backgroundTransactionRefreshEnabled = true
        state.settings.simplefinBackgroundSyncEnabled = true

        #expect(!state.isExperimentalFeatureEnabled(.bankSync))
        #expect(!state.settings.isBackgroundBankSyncEnabled)
        #expect(state.settings.wantsBackgroundAppRefresh)

        state.updateExperimentalFeature(.bankSync, isEnabled: true)
        #expect(state.isExperimentalFeatureEnabled(.bankSync))
        #expect(state.settings.isBackgroundBankSyncEnabled)
        #expect(state.settings.backgroundTransactionRefreshEnabled)

        state.updateExperimentalFeature(.bankSync, isEnabled: false)
        #expect(!state.isExperimentalFeatureEnabled(.bankSync))
        #expect(!state.settings.simplefinBackgroundSyncEnabled)
        #expect(!state.settings.isBackgroundBankSyncEnabled)
        #expect(state.settings.backgroundTransactionRefreshEnabled)
        #expect(state.settings.wantsBackgroundAppRefresh)
    }

    @Test func leftoverBackgroundBankSyncClearsWhenExperimentalIsOff() {
        let defaultsName = "ActualistTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let store = AppSettingsStore(defaults: defaults)
        var settings = AppSettings()
        settings.simplefinBackgroundSyncEnabled = true
        settings.backgroundTransactionRefreshEnabled = true
        store.save(settings)

        let state = AppState(
            settingsStore: store,
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString
            )
        )

        #expect(!state.isExperimentalFeatureEnabled(.bankSync))
        #expect(!state.settings.simplefinBackgroundSyncEnabled)
        #expect(state.settings.backgroundTransactionRefreshEnabled)
        #expect(state.settings.wantsBackgroundAppRefresh)
    }

    @Test func backgroundBankSyncToggleRequiresExperimentalFeature() async {
        let state = makeAppState()

        await state.updateSimpleFINBackgroundSyncEnabled(true)

        #expect(!state.settings.simplefinBackgroundSyncEnabled)
        #expect(!state.settings.isBackgroundBankSyncEnabled)
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
