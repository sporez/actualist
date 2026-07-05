import Foundation
import Testing
@testable import Actualist

@MainActor
struct BackendCapabilitiesTests {
    // MARK: Struct truth table

    @Test func restOnlineAllowsEveryWrite() {
        let capabilities = BackendCapabilities(isLocalFirst: false, isReadOnly: false)

        #expect(capabilities.canAssignBudget)
        #expect(capabilities.canCreateTransactions)
        #expect(capabilities.canCategorizeTransactions)
        #expect(capabilities.canUpdateSimpleTransactions)
        #expect(capabilities.canDeleteTransactions)
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
        #expect(!capabilities.canCreateTransactions)
        #expect(!capabilities.canCategorizeTransactions)
        #expect(!capabilities.canUpdateSimpleTransactions)
        #expect(!capabilities.canDeleteTransactions)
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
        #expect(!capabilities.canCreateTransactions)
        #expect(!capabilities.canCategorizeTransactions)
        #expect(!capabilities.canUpdateSimpleTransactions)
        #expect(!capabilities.canDeleteTransactions)
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

    @Test func localFirstDeveloperWriteGateAllowsCreateAndCategorizeOnly() {
        let capabilities = BackendCapabilities(
            isLocalFirst: true,
            isReadOnly: true,
            allowsLocalFirstTransactionCreation: true
        )

        #expect(capabilities.canCreateTransactions)
        #expect(capabilities.canCategorizeTransactions)
        #expect(capabilities.canUpdateSimpleTransactions)
        #expect(capabilities.canDeleteTransactions)
        #expect(!capabilities.canAssignBudget)
        #expect(!capabilities.canEditTransactions)
        #expect(!capabilities.canBankSync)
        #expect(!capabilities.canReconcile)
        #expect(!capabilities.canApplyRules)
        #expect(!capabilities.showsAddAccount)
        #expect(!capabilities.canAddAccount)
    }

    // MARK: AppState derivation

    @Test func appStateIsAlwaysLocalFirstReadOnly() {
        // Local-first is the only backend, and it stays read-only until the CRDT write phase,
        // regardless of setup phase or connection status.
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
                #expect(!capabilities.canEditTransactions)
                #expect(!capabilities.showsAddAccount)
            }
        }
    }

    @Test func appStateDeveloperWriteGateAllowsCreateAndCategorizeOnly() {
        let state = makeAppState()
        state.updateLocalFirstTransactionCreationEnabled(true)

        let capabilities = state.capabilities
        #expect(capabilities.isLocalFirst)
        #expect(capabilities.isReadOnly)
        #expect(capabilities.canCreateTransactions)
        #expect(capabilities.canCategorizeTransactions)
        #expect(capabilities.canUpdateSimpleTransactions)
        #expect(capabilities.canDeleteTransactions)
        #expect(!capabilities.canEditTransactions)
        #expect(!capabilities.canAssignBudget)
        #expect(!capabilities.canBankSync)
    }

    @Test func hidingDeveloperModeDisablesLocalFirstTransactionCreation() {
        let state = makeAppState()
        state.updateDeveloperModeUnlocked(true)
        state.updateLocalFirstTransactionCreationEnabled(true)

        state.updateDeveloperModeUnlocked(false)

        #expect(!state.settings.developerModeUnlocked)
        #expect(!state.settings.localFirstTransactionCreationEnabled)
        #expect(!state.capabilities.canCreateTransactions)
        #expect(!state.capabilities.canCategorizeTransactions)
        #expect(!state.capabilities.canUpdateSimpleTransactions)
        #expect(!state.capabilities.canDeleteTransactions)
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
