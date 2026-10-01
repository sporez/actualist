import SwiftUI

/// Selection-mode toolbar piece extracted from `AccountTransactionsView` so the
/// duplicate/merge command wiring keeps that screen under the structural
/// file-size gate. Pure presentation forwarding: no state is owned here.
struct AccountTransactionsSelectionToolbar: ToolbarContent {
    let batchPresentation: TransactionBatchPresentation
    let feedSnapshot: TransactionBatchFeedSnapshot?
    let budgetID: String?
    let transactionRepository: any TransactionRepositoryProtocol
    let appState: AppState

    var body: some ToolbarContent {
        TransactionSelectionBar(
            selectedCount: batchPresentation.selectedCount,
            canAct: batchPresentation.canActOnSelection,
            onDone: { batchPresentation.exitSelection() },
            onClear: {
                batchPresentation.prepare(
                    intent: .clear,
                    feedSnapshot: feedSnapshot,
                    repository: appState.localFirstStore
                )
            },
            onCategorize: {
                batchPresentation.presentCategoryPicker(
                    budgetID: budgetID,
                    repository: transactionRepository
                )
            },
            onDelete: {
                batchPresentation.prepare(
                    intent: .delete,
                    feedSnapshot: feedSnapshot,
                    repository: appState.localFirstStore
                )
            },
            onDuplicate: {
                batchPresentation.prepareDuplicate(
                    feedSnapshot: feedSnapshot,
                    repository: appState.localFirstStore
                )
            },
            onMerge: {
                batchPresentation.prepareMerge(
                    feedSnapshot: feedSnapshot,
                    repository: appState.localFirstStore
                )
            }
        )
    }
}
