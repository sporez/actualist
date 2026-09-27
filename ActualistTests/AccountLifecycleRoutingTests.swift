import Foundation
import Testing
@testable import Actualist

@MainActor
struct AccountLifecycleRoutingTests {
    @Test(arguments: [AccountLifecycleOperation.close, .delete])
    func committedRemovalLeavesMatchingDetailsEvenWhenRefreshIsPending(
        operation: AccountLifecycleOperation
    ) throws {
        let state = try makeState()
        let account = account()
        state.accountNavigationPath = [account]
        AccountLifecycleRouting.completionHandler(using: state)(
            identity(), outcome(operation, refreshPending: true)
        )
        let receipt = try #require(state.routeCoordinator.pendingAccountLifecycleReceipt)

        #expect(state.routeCoordinator.readyAccountLifecycleReceiptID == nil)
        #expect(AccountLifecycleRouting.consume(
            receiptID: receipt.id, using: state, selection: .account(account)
        ) == .account(account))
        #expect(state.accountNavigationPath == [account])
        state.routeCoordinator.accountLifecycleSavedNoticeDismissed(receiptID: receipt.id)

        let selection = AccountLifecycleRouting.consume(
            receiptID: receipt.id, using: state, selection: .account(account)
        )

        #expect(selection == .accounts)
        #expect(state.accountNavigationPath.isEmpty)
        #expect(state.routeCoordinator.pendingAccountLifecycleReceipt == nil)
        #expect(state.localDataRevision == 1)
    }

    @Test func removalPreservesUnrelatedNavigation() throws {
        let state = try makeState()
        let other = account(id: "other")
        state.accountNavigationPath = [other]
        AccountLifecycleRouting.completionHandler(using: state)(identity(), outcome(.delete))
        let receipt = try #require(state.routeCoordinator.pendingAccountLifecycleReceipt)

        #expect(AccountLifecycleRouting.consume(
            receiptID: receipt.id, using: state, selection: .account(other)
        ) == .account(other))
        #expect(state.accountNavigationPath == [other])
        #expect(state.routeCoordinator.pendingAccountLifecycleReceipt == nil)
    }

    @Test func refreshedCloseIsReadyWithoutAnAcknowledgement() throws {
        let state = try makeState()
        state.accountNavigationPath = [account()]
        AccountLifecycleRouting.completionHandler(using: state)(identity(), outcome(.close))
        let id = try #require(state.routeCoordinator.readyAccountLifecycleReceiptID)
        #expect(AccountLifecycleRouting.consume(
            receiptID: id, using: state, selection: .account(account())
        ) == .accounts)
        #expect(state.accountNavigationPath.isEmpty)
    }

    @Test(arguments: [AccountLifecycleOperation.rename, .reopen])
    func metadataChangesRefreshBothRouteValuesFromCurrentCache(
        operation: AccountLifecycleOperation
    ) throws {
        let state = try makeState()
        let old = account(name: "Old", closed: true)
        let current = account(name: "Current", closed: false)
        state.accountNavigationPath = [old]
        state.localFirstStore.accountsByBudget["budget"] = [AccountDisplay(account: current, balance: 0)]
        AccountLifecycleRouting.completionHandler(using: state)(identity(), outcome(operation))
        let receipt = try #require(state.routeCoordinator.pendingAccountLifecycleReceipt)

        #expect(AccountLifecycleRouting.consume(
            receiptID: receipt.id, using: state, selection: .account(old)
        ) == .account(current))
        #expect(state.accountNavigationPath == [current])
    }

    @Test func completionRejectsDifferentBudgetAccountAndReopenedSession() throws {
        let state = try makeState()
        let completion = AccountLifecycleRouting.completionHandler(using: state)
        completion(.init(budgetID: "other", accountID: "account"), outcome(.close))
        completion(.init(budgetID: "budget", accountID: "other"), outcome(.close))
        #expect(state.routeCoordinator.pendingAccountLifecycleReceipt == nil)
        #expect(state.localDataRevision == 0)

        state.localFirstStore.closeOpenBudget()
        completion(identity(), outcome(.close))
        #expect(state.routeCoordinator.pendingAccountLifecycleReceipt == nil)
        #expect(state.localDataRevision == 0)
    }

    @Test func receiptCannotNavigateAReplacementSessionOrBudget() throws {
        for changesBudget in [false, true] {
            let state = try makeState()
            let account = account()
            state.accountNavigationPath = [account]
            AccountLifecycleRouting.completionHandler(using: state)(identity(), outcome(.close))
            let receipt = try #require(state.routeCoordinator.pendingAccountLifecycleReceipt)
            if changesBudget {
                state.settings.selectedBudgetID = "other"
            } else {
                state.localFirstStore.closeOpenBudget()
            }

            #expect(AccountLifecycleRouting.consume(
                receiptID: receipt.id, using: state, selection: .account(account)
            ) == .account(account))
            #expect(state.accountNavigationPath == [account])
            #expect(state.routeCoordinator.pendingAccountLifecycleReceipt == nil)
        }
    }

    @Test func oldReceiptConsumptionCannotClearNewReceipt() throws {
        let state = try makeState()
        let completion = AccountLifecycleRouting.completionHandler(using: state)
        completion(identity(), outcome(.close))
        let old = try #require(state.routeCoordinator.pendingAccountLifecycleReceipt)
        completion(identity(), outcome(.delete))
        let current = try #require(state.routeCoordinator.pendingAccountLifecycleReceipt)

        state.routeCoordinator.accountLifecycleSavedNoticeDismissed(receiptID: old.id)
        #expect(AccountLifecycleRouting.consume(
            receiptID: old.id, using: state, selection: .reports
        ) == .reports)
        #expect(state.routeCoordinator.pendingAccountLifecycleReceipt == current)
        state.routeCoordinator.reset()
        #expect(state.routeCoordinator.pendingAccountLifecycleReceipt == nil)
    }

    private func makeState() throws -> AppState {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID())"))
        let state = AppState(
            settingsStore: AppSettingsStore(defaults: defaults),
            keychain: KeychainStore(
                service: "ActualistTests.Routing",
                account: UUID().uuidString,
                backend: FakeKeychainBackend()
            )
        )
        state.settings.selectedBudgetID = "budget"
        return state
    }

    private func identity() -> AccountLifecycleIdentity {
        AccountLifecycleIdentity(budgetID: "budget", accountID: "account")
    }

    private func account(
        id: String = "account", name: String = "Checking", closed: Bool = false
    ) -> ActualAccount {
        ActualAccount(id: id, name: name, offbudget: false, closed: closed)
    }

    private func outcome(
        _ operation: AccountLifecycleOperation, refreshPending: Bool = false
    ) -> AccountLifecycleOutcome {
        AccountLifecycleOutcome(
            operation: operation,
            account: AccountLifecycleAccount(
                id: "account", name: "Checking", offBudget: false,
                isClosed: operation == .close, accountGroupID: nil
            ),
            refreshPending: refreshPending
        )
    }
}
