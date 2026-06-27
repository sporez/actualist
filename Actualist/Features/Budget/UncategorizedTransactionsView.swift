import SwiftUI

struct UncategorizedTransactionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    @State private var viewModel = UncategorizedTransactionsViewModel()
    @State private var selectedTransaction: SelectedUncategorizedTransaction?

    let month: String
    let onChanged: () -> Void
    let onResolvedAll: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                ActualistTheme.background.ignoresSafeArea()

                content
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
            }
            .navigationTitle("Uncategorized")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.load(month: month, using: appState) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isLoading)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            await viewModel.load(month: month, using: appState)
        }
        .sheet(item: $selectedTransaction) { selection in
            TransactionCategorySelectionView(
                categoryGroups: viewModel.categoryGroups,
                selectedCategoryID: nil,
                isLoading: viewModel.isLoading,
                showsUncategorizedOption: false
            ) { option in
                Task {
                    let resolved = await viewModel.categorize(
                        selection.transaction,
                        as: option,
                        using: appState
                    )
                    if resolved, viewModel.transactions.isEmpty {
                        onChanged()
                        onResolvedAll()
                        dismiss()
                    } else if resolved {
                        onChanged()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading, viewModel.transactions.isEmpty {
            GlassPanel {
                HStack {
                    ProgressView()
                    Text("Loading transactions")
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .frame(maxWidth: .infinity)
            }
        } else if viewModel.transactions.isEmpty {
            GlassPanel {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(ActualistTheme.positive)
                    Text("No uncategorized transactions")
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.primaryText)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(ActualistTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.transactionGroups, id: \.date) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.title)
                                    .font(ActualistTypography.sectionTitle(for: density))
                                    .foregroundStyle(ActualistTheme.primaryText)
                                    .padding(.horizontal, density.rowHorizontalPadding)

                                VStack(spacing: 0) {
                                    ForEach(Array(group.transactions.enumerated()), id: \.element.rowID) { index, transaction in
                                        uncategorizedButton(
                                            for: transaction,
                                            showsBottomSeparator: index < group.transactions.count - 1
                                        )
                                    }
                                }
                                .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func uncategorizedButton(
        for transaction: ActualTransaction,
        showsBottomSeparator: Bool
    ) -> some View {
        Button {
            guard !appState.isReadOnly, viewModel.categorizingTransactionID == nil else {
                return
            }
            selectedTransaction = SelectedUncategorizedTransaction(transaction: transaction)
        } label: {
            ZStack(alignment: .trailing) {
                TransactionRow(
                    transaction: transaction,
                    payeeName: viewModel.payeeName(for: transaction),
                    categoryNames: viewModel.categoryNames(for: transaction),
                    showsBottomSeparator: showsBottomSeparator
                )

                if viewModel.categorizingTransactionID == transaction.rowID {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                            .background(ActualistTheme.surface, in: Circle())
                    }
                    .padding(.trailing, density.rowHorizontalPadding)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SelectedUncategorizedTransaction: Identifiable {
    let transaction: ActualTransaction

    var id: String {
        transaction.rowID
    }
}
