import SwiftUI

struct TransactionBatchPresentationHost: ViewModifier {
    @Bindable var presentation: TransactionBatchPresentation
    let selectedBudgetID: String?
    let sessionGeneration: Int
    let context: TransactionSelectionContext?
    let feedSnapshot: @MainActor () -> TransactionBatchFeedSnapshot?
    let batchRepository: any TransactionBatchRepositoryProtocol
    let onCommitted: @MainActor (TransactionBatchOutcome) -> Void
    let duplicateRepository: any TransactionDuplicateRepositoryProtocol
    let mergeRepository: any TransactionMergeRepositoryProtocol
    let onDuplicateCommitted: @MainActor (TransactionDuplicateOutcome) -> Void
    let onMergeCommitted: @MainActor (TransactionMergeOutcome) -> Void

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
            repository: duplicateRepository,
            currentFeedSnapshot: feedSnapshot,
            onCommitted: onDuplicateCommitted
        )
    }

    private func confirmMerge() {
        presentation.confirmMerge(
            repository: mergeRepository,
            currentFeedSnapshot: feedSnapshot,
            onCommitted: onMergeCommitted
        )
    }
}
