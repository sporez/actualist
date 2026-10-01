import SwiftUI

struct TransactionFeedFilterMenu: View {

    let viewModel: AccountTransactionsViewModel
    let budgetID: String?
    let repository: any TransactionRepositoryProtocol
    let onMoreFilters: () -> Void
    let onSavedFilters: () -> Void
    var showsTitle = false

    var body: some View {
        TransactionStatusFilterMenu(
            selection: viewModel.statusFilter,
            showsTitle: showsTitle,
            onMoreFilters: onMoreFilters,
            onSavedFilters: onSavedFilters,
            onSelect: selectFilter
        )
    }

    private func selectFilter(_ filter: TransactionStatusFilter) {
        Task { await viewModel.selectFilter(filter, budgetID: budgetID, repository: repository) }
    }

}
