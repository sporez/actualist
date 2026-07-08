import Foundation
import Testing
@testable import Actualist

@MainActor
struct BackendCapabilitiesTests {
    // MARK: Struct truth table

    @Test func restOnlineAllowsEveryWrite() {
        let capabilities = BackendCapabilities(isLocalFirst: false, isReadOnly: false)

        #expect(capabilities.canAssignBudget)
        #expect(capabilities.canAssignCategoryBudget)
        #expect(capabilities.canMoveMoney)
        #expect(capabilities.canApplyBudgetTemplates)
        #expect(capabilities.canCreateTransactions)
        #expect(capabilities.canCategorizeTransactions)
        #expect(capabilities.canUpdateSimpleTransactions)
        #expect(capabilities.canDeleteTransactions)
        #expect(capabilities.canWriteTransfers)
        #expect(capabilities.canWriteSplits)
        #expect(capabilities.canEditTransactions)
        #expect(capabilities.canBankSync)
        #expect(capabilities.canReconcile)
        #expect(capabilities.canApplyRules)
        #expect(capabilities.showsAddAccount)
        #expect(capabilities.canAddAccount)
        #expect(capabilities.supportsBackgroundRefresh)
        #expect(capabilities.supportsTransactionNotifications)
    }

    @Test func restOfflineBlocksWritesButKeepsStructuralFeatures() {
        let capabilities = BackendCapabilities(isLocalFirst: false, isReadOnly: true)

        // Writes are blocked while offline...
        #expect(!capabilities.canAssignBudget)
        #expect(!capabilities.canAssignCategoryBudget)
        #expect(!capabilities.canMoveMoney)
        #expect(!capabilities.canApplyBudgetTemplates)
        #expect(!capabilities.canCreateTransactions)
        #expect(!capabilities.canCategorizeTransactions)
        #expect(!capabilities.canUpdateSimpleTransactions)
        #expect(!capabilities.canDeleteTransactions)
        #expect(!capabilities.canWriteTransfers)
        #expect(!capabilities.canWriteSplits)
        #expect(!capabilities.canEditTransactions)
        #expect(!capabilities.canBankSync)
        #expect(!capabilities.canReconcile)
        #expect(!capabilities.canApplyRules)
        #expect(!capabilities.canAddAccount)

        // ...but REST structural affordances stay present (visible, just disabled).
        #expect(capabilities.showsAddAccount)
        #expect(capabilities.supportsBackgroundRefresh)
        #expect(capabilities.supportsTransactionNotifications)
    }

    @Test func localFirstBlocksWritesButAllowsReadOnlyRefreshNotifications() {
        let capabilities = BackendCapabilities(isLocalFirst: true, isReadOnly: true)

        #expect(!capabilities.canAssignBudget)
        #expect(!capabilities.canAssignCategoryBudget)
        #expect(!capabilities.canMoveMoney)
        #expect(!capabilities.canApplyBudgetTemplates)
        #expect(!capabilities.canCreateTransactions)
        #expect(!capabilities.canCategorizeTransactions)
        #expect(!capabilities.canUpdateSimpleTransactions)
        #expect(!capabilities.canDeleteTransactions)
        #expect(!capabilities.canWriteTransfers)
        #expect(!capabilities.canWriteSplits)
        #expect(!capabilities.canEditTransactions)
        #expect(!capabilities.canBankSync)
        #expect(!capabilities.canReconcile)
        #expect(!capabilities.canApplyRules)

        // Local-first keeps write affordances hidden, but background refresh is read-only:
        // it pulls sync messages and notifies if new transaction rows appear.
        #expect(!capabilities.showsAddAccount)
        #expect(!capabilities.canAddAccount)
        #expect(capabilities.supportsBackgroundRefresh)
        #expect(capabilities.supportsTransactionNotifications)
    }

    @Test func localFirstWriteGateEnablesEveryImplementedWrite() {
        // One developer flag now gates all local-first writes together.
        let capabilities = BackendCapabilities(
            isLocalFirst: true,
            isReadOnly: true,
            allowsLocalFirstWrites: true
        )

        // Implemented local-first writes.
        #expect(capabilities.canCreateTransactions)
        #expect(capabilities.canCategorizeTransactions)
        #expect(capabilities.canUpdateSimpleTransactions)
        #expect(capabilities.canDeleteTransactions)
        #expect(capabilities.canWriteTransfers)
        #expect(capabilities.canWriteSplits)
        #expect(capabilities.canAssignCategoryBudget)
        #expect(capabilities.canMoveMoney)
        #expect(capabilities.canApplyBudgetTemplates)
        #expect(capabilities.canAssignBudget)

        // Still not implemented for local-first.
        #expect(!capabilities.canEditTransactions)
        #expect(!capabilities.canBankSync)
        #expect(!capabilities.canReconcile)
        #expect(!capabilities.canApplyRules)
        #expect(capabilities.showsAddAccount)
        #expect(capabilities.canAddAccount)
    }

    @Test func newTransactionNotificationCopyIsGeneric() {
        #expect(NewTransactionsNotificationCopy.title == "Actualist")
        #expect(NewTransactionsNotificationCopy.body == "New transactions found")
    }

    // MARK: AppState derivation

    @Test func appStateIsAlwaysLocalFirstReadOnly() {
        // Local-first is the only backend. Write surfaces stay gated unless the developer
        // local write switch is enabled, regardless of setup phase or connection status.
        for phase in [SetupPhase.needsConnection, .selectingBudget, .ready] {
            for status in [ServerConnectionStatus.online, .connecting, .offline] {
                let state = makeAppState()
                state.setupPhase = phase
                state.connectionStatus = status

                let capabilities = state.capabilities
                #expect(capabilities.isLocalFirst)
                #expect(capabilities.isReadOnly)
                #expect(!capabilities.canCreateTransactions)
                #expect(!capabilities.canCategorizeTransactions)
                #expect(!capabilities.canUpdateSimpleTransactions)
                #expect(!capabilities.canDeleteTransactions)
                #expect(!capabilities.canWriteTransfers)
                #expect(!capabilities.canWriteSplits)
                #expect(!capabilities.canEditTransactions)
                #expect(!capabilities.canAssignCategoryBudget)
                #expect(!capabilities.canMoveMoney)
                #expect(!capabilities.canApplyBudgetTemplates)
                #expect(!capabilities.showsAddAccount)
                #expect(!capabilities.canAddAccount)
            }
        }
    }

    @Test func appStateDeveloperWriteGateAllowsCurrentLocalFirstWrites() {
        let state = makeAppState()
        state.updateLocalFirstWritesEnabled(true)

        let capabilities = state.capabilities
        #expect(capabilities.isLocalFirst)
        #expect(capabilities.isReadOnly)
        #expect(capabilities.canCreateTransactions)
        #expect(capabilities.canCategorizeTransactions)
        #expect(capabilities.canUpdateSimpleTransactions)
        #expect(capabilities.canDeleteTransactions)
        #expect(capabilities.canWriteTransfers)
        #expect(capabilities.canWriteSplits)
        #expect(capabilities.canAssignBudget)
        #expect(capabilities.canAssignCategoryBudget)
        #expect(capabilities.canMoveMoney)
        #expect(capabilities.canApplyBudgetTemplates)
        #expect(capabilities.showsAddAccount)
        #expect(capabilities.canAddAccount)
        #expect(!capabilities.canEditTransactions)
        #expect(!capabilities.canBankSync)
    }

    @Test func hidingDeveloperModeDisablesLocalFirstTransactionCreation() {
        let state = makeAppState()
        state.updateDeveloperModeUnlocked(true)
        state.updateLocalFirstWritesEnabled(true)

        state.updateDeveloperModeUnlocked(false)

        #expect(!state.settings.developerModeUnlocked)
        #expect(!state.settings.localFirstWritesEnabled)
        #expect(!state.capabilities.canCreateTransactions)
        #expect(!state.capabilities.canCategorizeTransactions)
        #expect(!state.capabilities.canUpdateSimpleTransactions)
        #expect(!state.capabilities.canDeleteTransactions)
        #expect(!state.capabilities.canWriteTransfers)
        #expect(!state.capabilities.canWriteSplits)
        #expect(!state.capabilities.canAssignCategoryBudget)
        #expect(!state.capabilities.canMoveMoney)
        #expect(!state.capabilities.canAddAccount)
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
