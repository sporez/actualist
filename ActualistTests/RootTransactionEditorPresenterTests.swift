import Testing
@testable import Actualist

@MainActor
struct RootTransactionEditorPresenterTests {
    @Test func consumesNewTransactionRouteAndRetainsPrefill() {
        let coordinator = AppRouteCoordinator()
        let prefill = ShortcutEditorPrefill(
            accountID: "checking",
            payeeName: "Coffee",
            categoryName: "Dining"
        )
        coordinator.enqueue(.newTransaction(prefill))
        let presenter = RootTransactionEditorPresenter()

        #expect(presenter.consumeNewTransaction(from: coordinator))
        #expect(presenter.presentation?.prefill == prefill)
        #expect(coordinator.pendingRoute == nil)
    }

    @Test func resolvesPrefilledAccountFromCurrentDisplays() {
        let presenter = RootTransactionEditorPresenter()
        let prefill = ShortcutEditorPrefill(accountID: "checking")
        presenter.present(prefill: prefill)
        let checking = ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false)
        let displays = [AccountDisplay(account: checking, balance: 0)]

        #expect(presenter.presentation?.prefilledAccount(from: displays) == checking)
    }
}
