import SwiftUI

struct AccountTransactionActionsMenu: View {
    let accountID: String
    let lifecycleCoordinator: AccountLifecycleCoordinator
    let viewModel: AccountTransactionsViewModel
    let budgetID: String?
    let repository: any TransactionRepositoryProtocol
    let onReconcile: () -> Void
    let onMoreFilters: () -> Void
    let onSavedFilters: () -> Void
    let onSelectTransactions: () -> Void
    let onExportCSV: () -> Void
    let onImportCSV: () -> Void

    var body: some View {
        Menu {
            AccountLifecycleMenu(accountID: accountID, coordinator: lifecycleCoordinator)
            Button(action: onReconcile) {
                Label("Reconcile", systemImage: "checkmark.seal")
            }
            Menu {
                Button(action: onImportCSV) {
                    Label("Import CSV…", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("account-import-csv")
                Button(action: onExportCSV) {
                    Label("Export CSV…", systemImage: "tablecells")
                }
                .accessibilityIdentifier("account-export-csv")
            } label: {
                Label("Import / Export", systemImage: "square.and.arrow.up.on.square")
            }
            .accessibilityIdentifier("account-import-export-menu")

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
        .accessibilityLabel("Account Actions")
    }
}
