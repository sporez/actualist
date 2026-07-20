import Foundation
import Testing
@testable import Actualist

@MainActor
struct BackendCapabilitiesTests {
    @Test func localFirstEnablesEveryImplementedWrite() {
        let capabilities = BackendCapabilities.localFirst

        #expect(capabilities.canCreateTransactions)
        #expect(capabilities.canCategorizeTransactions)
        #expect(capabilities.canUpdateSimpleTransactions)
        #expect(capabilities.canDeleteTransactions)
        #expect(capabilities.canWriteTransfers)
        #expect(capabilities.canWriteSplits)
        #expect(capabilities.canAssignCategoryBudget)
        #expect(capabilities.canSetCategoryCarryover)
        #expect(capabilities.canMoveMoney)
        #expect(capabilities.canApplyBudgetTemplates)
        #expect(capabilities.canAssignBudget)
        #expect(capabilities.showsAddAccount)
        #expect(capabilities.canAddAccount)
        #expect(capabilities.supportsBackgroundRefresh)
        #expect(capabilities.supportsTransactionNotifications)
    }

    @Test func localFirstKeepsUnimplementedWritesUnavailable() {
        let capabilities = BackendCapabilities.localFirst

        #expect(!capabilities.canReconcile)
        #expect(!capabilities.canApplyRules)
    }

    @Test func newTransactionNotificationCopyIsGeneric() {
        #expect(NewTransactionsNotificationCopy.title == "Actualist")
        #expect(NewTransactionsNotificationCopy.body == "New transactions found")
    }

    // MARK: AppState derivation

    @Test func appStateKeepsProvenWritesAvailableOfflineAndOutsideDeveloperMode() {
        for phase in [SetupPhase.needsConnection, .selectingBudget, .restoringBudget, .ready] {
            for status in [ServerConnectionStatus.online, .connecting, .offline] {
                let state = makeAppState()
                state.setupPhase = phase
                state.connectionStatus = status
                state.updateDeveloperModeUnlocked(false)

                let capabilities = state.capabilities
                #expect(capabilities.canCreateTransactions)
                #expect(capabilities.canCategorizeTransactions)
                #expect(capabilities.canUpdateSimpleTransactions)
                #expect(capabilities.canDeleteTransactions)
                #expect(capabilities.canWriteTransfers)
                #expect(capabilities.canWriteSplits)
                #expect(capabilities.canAssignCategoryBudget)
                #expect(capabilities.canSetCategoryCarryover)
                #expect(capabilities.canMoveMoney)
                #expect(capabilities.canApplyBudgetTemplates)
                #expect(capabilities.showsAddAccount)
                #expect(capabilities.canAddAccount)
            }
        }
    }

    @Test func budgetTemplatesRequireExperimentalFeature() {
        let state = makeAppState()

        #expect(state.capabilities.canApplyBudgetTemplates)
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

    @Test func clearingBudgetPendingNewTransactionsClearsEveryAccountInBudgetOnly() {
        let state = makeAppState()
        state.settings.pendingNewTransactionIDsByAccount = [
            "budget|checking": ["txn-1"],
            "budget|credit": ["txn-2"],
            "other|checking": ["txn-3"]
        ]

        state.clearPendingNewTransactionIDs(budgetID: "budget")

        #expect(state.settings.pendingNewTransactionIDsByAccount["budget|checking"] == nil)
        #expect(state.settings.pendingNewTransactionIDsByAccount["budget|credit"] == nil)
        #expect(state.settings.pendingNewTransactionIDsByAccount["other|checking"] == ["txn-3"])
    }

    private func makeAppState() -> AppState {
        let defaultsName = "ActualistTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        return AppState(
            settingsStore: AppSettingsStore(defaults: defaults),
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString
            )
        )
    }
}
