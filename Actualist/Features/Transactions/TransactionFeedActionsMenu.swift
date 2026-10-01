import SwiftUI

struct TransactionFeedActionsMenu: View {
    let viewModel: AccountTransactionsViewModel
    let budgetID: String?
    let repository: any TransactionRepositoryProtocol
    let onMoreFilters: () -> Void
    let onSavedFilters: () -> Void
    let onSelectTransactions: () -> Void

    var body: some View {
        Menu {
            TransactionFeedFilterMenu(
                viewModel: viewModel,
                budgetID: budgetID,
                repository: repository,
                onMoreFilters: onMoreFilters,
                onSavedFilters: onSavedFilters,
                showsTitle: true
            )
            Button("Select Transactions", systemImage: "checkmark.circle", action: onSelectTransactions)
                .accessibilityIdentifier("transaction-selection-enter")
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Transaction Actions")
        .accessibilityIdentifier("transaction-actions-menu")
    }
}
