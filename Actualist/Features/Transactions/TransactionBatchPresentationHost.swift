import SwiftUI

struct TransactionBatchPresentationHost: ViewModifier {
    @Bindable var presentation: TransactionBatchPresentation
    let selectedBudgetID: String?
    let sessionGeneration: Int
    let context: TransactionSelectionContext?
    let feedSnapshot: @MainActor () -> TransactionBatchFeedSnapshot?
    let batchRepository: any TransactionBatchRepositoryProtocol
    let onCommitted: @MainActor (TransactionBatchOutcome) -> Void
    var duplicateRepository: (any TransactionDuplicateRepositoryProtocol)? = nil
    var mergeRepository: (any TransactionMergeRepositoryProtocol)? = nil
    var onDuplicateCommitted: (@MainActor (TransactionDuplicateOutcome) -> Void)? = nil
    var onMergeCommitted: (@MainActor (TransactionMergeOutcome) -> Void)? = nil

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: sheetBinding) {
                sheet
                    .appSwitcherPrivacyProtected(using: appState)
                    .interactiveDismissDisabled(presentation.preventsSheetDismissal)
            }
            .onChange(of: context) { _, context in presentation.contextChanged(to: context) }
            .onChange(of: selectedBudgetID) { _, _ in presentation.contextChanged(to: context) }
            .onChange(of: sessionGeneration) { presentation.sessionChanged() }
    }

    @Environment(AppState.self) private var appState

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { presentation.isSheetPresented },
            set: { if !$0 { presentation.cancelSheet() } }
        )
    }

    @ViewBuilder
    private var sheet: some View {
        switch presentation.commandSheet {
        case .duplicate:
            TransactionDuplicateCommandSheet(
                coordinator: presentation.duplicate,
                currency: currency,
                isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
                onCancel: { presentation.cancelSheet() },
                onConfirm: { confirmDuplicate() },
                onDone: { presentation.finishCommittedResult() }
            )
        case .merge:
            TransactionMergeCommandSheet(
                coordinator: presentation.merge,
                currency: currency,
                isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
                onCancel: { presentation.cancelSheet() },
                onConfirm: { confirmMerge() },
                onDone: { presentation.finishCommittedResult() }
            )
        case nil:
            TransactionBatchInteractionSheet(
                presentation: presentation,
                isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
                feedSnapshot: feedSnapshot,
                repository: batchRepository,
                onCommitted: onCommitted
            )
        }
    }

    private var currency: BudgetCurrency {
        appState.localFirstStore.budgetCurrency(budgetID: selectedBudgetID ?? "")
    }

    private func confirmDuplicate() {
        presentation.confirmDuplicate(
            repository: duplicateRepository ?? appState.localFirstStore,
            currentFeedSnapshot: feedSnapshot,
            onCommitted: { outcome in
                if let onDuplicateCommitted {
                    onDuplicateCommitted(outcome)
                } else if outcome.sessionCurrent {
                    appState.recordLocalDataMutation()
                }
            }
        )
    }

    private func confirmMerge() {
        presentation.confirmMerge(
            repository: mergeRepository ?? appState.localFirstStore,
            currentFeedSnapshot: feedSnapshot,
            onCommitted: { outcome in
                if let onMergeCommitted {
                    onMergeCommitted(outcome)
                } else if outcome.sessionCurrent {
                    appState.recordLocalDataMutation()
                }
            }
        )
    }
}
