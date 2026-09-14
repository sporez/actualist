import Foundation
import Observation

/// One opening of the editor, retained by the window rather than its source screen.
@MainActor
@Observable
final class TransactionEditorSession: Identifiable {
    struct Context: Equatable {
        let budgetID: String
        let serverURL: String

        init(budgetID: String, serverURL: String) {
            self.budgetID = budgetID
            self.serverURL = serverURL
        }

        @MainActor init?(appState: AppState) {
            guard let budgetID = appState.settings.selectedBudgetID else { return nil }
            self.init(budgetID: budgetID, serverURL: appState.settings.localFirstServerURLString)
        }
    }

    let id = UUID()
    let context: Context
    let model: TransactionEditorViewModel
    private let account: ActualAccount?
    private var preparation: Task<Void, Never>?
    private var hasPresentedFeedback = false
    private enum Lifecycle { case active, saved, invalidated }
    private var lifecycle: Lifecycle = .active

    init(
        context: Context,
        request: TransactionEditorPresentation = .create,
        account: ActualAccount? = nil,
        categoryName: String? = nil,
        prefill: ShortcutEditorPrefill? = nil
    ) {
        self.context = context
        self.account = account
        model = TransactionEditorViewModel(
            editing: request.transaction,
            payeeName: prefill?.payeeName ?? request.payeeName,
            categoryName: prefill?.categoryName ?? request.categoryName ?? categoryName
        )
        if let prefill { model.applyShortcutPrefill(prefill) }
    }

    /// Host reconstruction and returning from nested pickers share this session.
    func consumePresentationFeedback() -> Bool {
        guard lifecycle == .active, !hasPresentedFeedback else { return false }
        hasPresentedFeedback = true
        return true
    }

    func invalidate() {
        lifecycle = .invalidated
        preparation?.cancel()
        model.mutationCoordinator.cancel()
    }

    func isCurrent(_ context: Context?) -> Bool {
        lifecycle == .active && self.context == context
    }

    func prepare(using appState: AppState) async {
        guard isCurrent(Context(appState: appState)) else { return }
        if let preparation { await preparation.value; return }
        // A host reconstruction awaits the same work and never reapplies defaults.
        let task = Task { [self] in
            await model.load(using: appState, prefilledAccount: account)
            guard isCurrent(Context(appState: appState)), !Task.isCancelled else { return }
            if !model.isEditing, !model.selectedPayeeName.isEmpty {
                await model.previewRules(
                    budgetID: context.budgetID,
                    repository: appState.transactionRepository,
                    currentBudgetID: { appState.settings.selectedBudgetID }
                )
            }
        }
        preparation = task
        await task.value
    }

    func submit(using appState: AppState) async -> Bool {
        guard isCurrent(Context(appState: appState)),
              await model.submit(budgetID: context.budgetID, repository: appState.transactionRepository),
              isCurrent(Context(appState: appState)) else { return false }
        lifecycle = .saved
        appState.recordLocalDataMutation()
        return true
    }

    func confirmRuleDelete(using appState: AppState) async -> Bool {
        guard isCurrent(Context(appState: appState)),
              await model.confirmRuleDelete(using: appState),
              isCurrent(Context(appState: appState)) else { return false }
        lifecycle = .saved
        appState.recordLocalDataMutation()
        return true
    }

    func confirmReconciledMutation(
        using appState: AppState
    ) async -> TransactionEditorMutationCoordinator.Outcome {
        guard isCurrent(Context(appState: appState)) else { return .cancelled }
        let outcome = await model.confirmReconciledMutation(using: appState)
        guard isCurrent(Context(appState: appState)) else { return .cancelled }
        switch outcome {
        case .saved:
            lifecycle = .saved
            appState.recordLocalDataMutation()
        case .unlocked:
            appState.recordLocalDataMutation()
        case .awaitingReview, .failed, .cancelled:
            break
        }
        return outcome
    }
}
