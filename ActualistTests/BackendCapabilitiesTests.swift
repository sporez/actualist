import Foundation
import Testing
@testable import Actualist

@MainActor
struct BackendCapabilitiesTests {
    // MARK: Struct truth table

    @Test func restOnlineAllowsEveryWrite() {
        let capabilities = BackendCapabilities(isLocalFirst: false, isReadOnly: false)

        #expect(capabilities.canAssignBudget)
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

    @Test func localFirstBlocksWritesAndStructuralFeatures() {
        let capabilities = BackendCapabilities(isLocalFirst: true, isReadOnly: true)

        #expect(!capabilities.canAssignBudget)
        #expect(!capabilities.canEditTransactions)
        #expect(!capabilities.canBankSync)
        #expect(!capabilities.canReconcile)
        #expect(!capabilities.canApplyRules)

        // Local-first hides these features entirely, not merely disabled.
        #expect(!capabilities.showsAddAccount)
        #expect(!capabilities.canAddAccount)
        #expect(!capabilities.supportsBackgroundRefresh)
        #expect(!capabilities.supportsTransactionNotifications)
    }

    // MARK: AppState derivation

    @Test func localFirstModeIsAlwaysReadOnly() {
        let state = makeAppState()
        state.settings.backendMode = .localFirstSync
        state.setupPhase = .ready
        state.connectionStatus = .online

        let capabilities = state.capabilities
        #expect(capabilities.isLocalFirst)
        #expect(capabilities.isReadOnly)
    }

    @Test func restReadyOnlineAllowsWrites() {
        let state = makeAppState()
        state.settings.backendMode = .restAPI
        state.setupPhase = .ready
        state.connectionStatus = .online

        let capabilities = state.capabilities
        #expect(!capabilities.isLocalFirst)
        #expect(!capabilities.isReadOnly)
        #expect(capabilities.canEditTransactions)
    }

    @Test func restReadyOfflineIsTransientlyReadOnly() {
        let state = makeAppState()
        state.settings.backendMode = .restAPI
        state.setupPhase = .ready
        state.connectionStatus = .offline

        let capabilities = state.capabilities
        #expect(!capabilities.isLocalFirst)
        #expect(capabilities.isReadOnly)
        // Offline is not local-first, so Add Account stays visible.
        #expect(capabilities.showsAddAccount)
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
