import SwiftUI

/// Selection-mode toolbar piece extracted from `AccountTransactionsView` so the
/// duplicate/merge command wiring keeps that screen under the structural
/// file-size gate. Pure presentation forwarding: no state is owned here.
struct AccountTransactionsSelectionToolbar: ToolbarContent {
    let batchPresentation: TransactionBatchPresentation
    let feedContext: TransactionSelectionContext?
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
                    feedContext: feedContext,
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
                    feedContext: feedContext,
                    repository: appState.localFirstStore
                )
            },
            onDuplicate: {
                batchPresentation.prepareDuplicate(
                    feedContext: feedContext,
                    repository: appState.localFirstStore
                )
            },
            onMerge: {
                batchPresentation.prepareMerge(
                    feedContext: feedContext,
                    repository: appState.localFirstStore
                )
            }
        )
    }
}
