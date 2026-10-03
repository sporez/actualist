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

    @Test func backgroundBankSyncToggleDoesNotClearAlerts() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let settingsStore = AppSettingsStore(defaults: defaults)
        let backend = FakeKeychainBackend()
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString,
            backend: backend
        )
        try keychain.saveActualSyncToken("token")
        let state = AppState(settingsStore: settingsStore, keychain: keychain)
        state.settings.backgroundTransactionRefreshEnabled = true

        await state.updateSimpleFINBackgroundSyncEnabled(true)
        #expect(state.settings.simplefinBackgroundSyncEnabled)
        #expect(state.settings.backgroundTransactionRefreshEnabled)
        #expect(settingsStore.load().simplefinBackgroundSyncEnabled)

        await state.updateSimpleFINBackgroundSyncEnabled(false)
        #expect(!state.settings.simplefinBackgroundSyncEnabled)
        #expect(state.settings.backgroundTransactionRefreshEnabled)
        #expect(state.settings.wantsBackgroundAppRefresh)
        #expect(!settingsStore.load().simplefinBackgroundSyncEnabled)
    }

    @Test func persistedBackgroundBankSyncSurvivesAppStateStartup() {
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

        #expect(state.settings.simplefinBackgroundSyncEnabled)
        #expect(state.settings.backgroundTransactionRefreshEnabled)
        #expect(state.settings.wantsBackgroundAppRefresh)
    }

    @Test func transactionNotificationRoutingSelectsSpending() async {
        let state = makeAppState()
        state.settings.selectedBudgetID = "budget"
        state.selectedTab = .accounts
        state.accountNavigationPath = [
            ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false)
        ]

        await state.routeToSpendingFromNotification(budgetID: "budget")

        #expect(state.selectedTab == .spending)
        #expect(state.accountNavigationPath.isEmpty)
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

    @Test func staleDisappearReviewCannotClearAnotherBudget() async {
        let state = makeAppState()
        state.settings.selectedBudgetID = "new-budget"
        state.settings.pendingNewTransactionIDsByAccount = [
            "old-budget|checking": ["old-1"],
            "new-budget|checking": ["new-1"]
        ]

        await state.clearPendingNewTransactionIDs(.init(
            budgetID: "old-budget", accountID: "checking", transactionIDs: ["old-1"]
        ))

        #expect(state.settings.pendingNewTransactionIDsByAccount["old-budget|checking"] == ["old-1"])
        #expect(state.settings.pendingNewTransactionIDsByAccount["new-budget|checking"] == ["new-1"])
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
