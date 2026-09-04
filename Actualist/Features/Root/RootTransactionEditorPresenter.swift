import Observation

enum RootTransactionEditorPresentation: Identifiable, Equatable {
    case new(ShortcutEditorPrefill?)

    var id: String { "new-transaction" }

    var prefill: ShortcutEditorPrefill? {
        switch self { case .new(let prefill): prefill }
    }

    func prefilledAccount(from displays: [AccountDisplay]) -> ActualAccount? {
        guard let accountID = prefill?.accountID else { return nil }
        return displays.first { $0.account.id == accountID }?.account
    }
}

@MainActor
@Observable
final class RootTransactionEditorPresenter {
    var presentation: RootTransactionEditorPresentation?

    func present(prefill: ShortcutEditorPrefill? = nil) {
        presentation = .new(prefill)
    }

    @discardableResult
    func consumeNewTransaction(from coordinator: AppRouteCoordinator) -> Bool {
        guard case .newTransaction(let prefill) = coordinator.pendingRoute else { return false }
        presentation = .new(prefill)
        _ = coordinator.consume()
        return true
    }

}
