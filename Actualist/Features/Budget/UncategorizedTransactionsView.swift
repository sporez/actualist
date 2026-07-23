import SwiftUI

struct UncategorizedTransactionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    @State private var viewModel = UncategorizedTransactionsViewModel()
    @State private var selectedTransaction: SelectedUncategorizedTransaction?
    @State private var selectedDetent: PresentationDetent = .medium

    let month: String
    let onChanged: () -> Void
    let onResolvedAll: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                ActualistTheme.background.ignoresSafeArea()

                ScrollView {
                    content
                        .padding(.horizontal, 18)
                        .padding(.top, 18)
                        .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
                .refreshable {
                    await viewModel.refresh(month: month, using: appState)
                }
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
            }
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .task {
            await viewModel.load(month: month, using: appState)
            if viewModel.transactions.count >= 4 {
                selectedDetent = .large
            }
        }
        .onChange(of: appState.localDataRevision) {
            Task { await viewModel.load(month: month, using: appState) }
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
                        month: month,
                        using: appState
                    )
                    if resolved.didChange {
                        onChanged()
                    }

                    if resolved.resolvedAll {
                        onResolvedAll()
                        dismiss()
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
        } else if viewModel.transactions.isEmpty, let errorMessage = viewModel.errorMessage {
            GlassPanel {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title)
                        .foregroundStyle(ActualistTheme.danger)
                    Text(errorMessage)
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.primaryText)
                        .multilineTextAlignment(.center)
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
    }

    private func uncategorizedButton(
        for transaction: ActualTransaction,
        showsBottomSeparator: Bool
    ) -> some View {
        Button {
            guard appState.capabilities.canCategorizeTransactions, viewModel.categorizingTransactionID == nil else {
                return
            }
            selectedTransaction = SelectedUncategorizedTransaction(transaction: transaction)
        } label: {
            ZStack(alignment: .trailing) {
                TransactionRow(
                    transaction: transaction,
                    payeeName: displayPayeeName(for: transaction),
                    categoryNames: displayCategoryNames(for: transaction),
                    isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
                    highlightsIncomeAmounts: appState.settings.greenIncomeTransactionAmountsEnabled,
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

    private func displayPayeeName(for transaction: ActualTransaction) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return viewModel.payeeName(for: transaction)
        }

        return PrivacyDisplay.name(for: .payee, seed: "uncategorized-payee-\(transaction.rowID)")
    }

    private func displayCategoryNames(for transaction: ActualTransaction) -> [String] {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return viewModel.categoryNames(for: transaction)
        }

        return [PrivacyDisplay.name(for: .category, seed: "uncategorized-category-\(transaction.rowID)")]
    }
}

private struct SelectedUncategorizedTransaction: Identifiable {
    let transaction: ActualTransaction

    var id: String {
        transaction.rowID
    }
}
