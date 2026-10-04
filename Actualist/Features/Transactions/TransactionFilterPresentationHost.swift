import Observation
import SwiftUI

@MainActor
@Observable
final class TransactionFilterPresentation {
    let workflow = TransactionFilterWorkflow()
    let savedFilters = SavedTransactionFiltersPresentation()
    private(set) var isPresented = false

    func present(
        viewModel: AccountTransactionsViewModel,
        budgetID: String?,
        repository: any TransactionRepositoryProtocol
    ) {
        let model = viewModel
        workflow.configure(
            conditions: viewModel.activeFeedQuery.conditions,
            join: viewModel.activeFeedQuery.conditionsJoin,
            onApply: { conditions, join in
                Task {
                    await model.applyStructuredConditions(
                        conditions,
                        join: join,
                        budgetID: budgetID,
                        repository: repository
                    )
                }
            }
        )
        isPresented = true
    }

    func dismiss() {
        workflow.cancelLoading()
        isPresented = false
    }
}

struct TransactionFilterPresentationHost: ViewModifier {
    @Environment(AppState.self) private var appState
    @Bindable var presentation: TransactionFilterPresentation

    func body(content: Content) -> some View {
        content
            .modifier(SavedTransactionFiltersPresentationHost(presentation: presentation.savedFilters))
            .sheet(isPresented: sheetBinding) {
                if let budgetID = appState.settings.selectedBudgetID {
                    TransactionFilterSheet(
                        workflow: presentation.workflow,
                        budgetID: budgetID,
                        repository: appState.transactionRepository,
                        availableAccounts: appState.accountRepository
                            .accountDisplays(budgetID: budgetID)
                            .map(\.account)
                    )
                    .appSwitcherPrivacyProtected(using: appState)
                } else {
                    ChooseBudgetUnavailableView()
                }
            }
            .onBudgetSessionChange { presentation.dismiss() }
    }

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { presentation.isPresented },
            set: { if !$0 { presentation.dismiss() } }
        )
    }
}
