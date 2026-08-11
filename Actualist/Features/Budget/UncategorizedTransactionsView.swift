import SwiftUI

struct UncategorizedTransactionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    @State private var viewModel = UncategorizedTransactionsViewModel()
    @State private var selectedTransaction: SelectedUncategorizedTransaction?
    @State private var isBulkCategoryPickerPresented = false
    @State private var selectedDetent: PresentationDetent = .medium

    let month: String
    let onChanged: () -> Void
    let onResolvedAll: () -> Void

    init(
        month: String,
        cachedSnapshot: LoadedUncategorizedTransactions?,
        onChanged: @escaping () -> Void,
        onResolvedAll: @escaping () -> Void
    ) {
        self.month = month
        self.onChanged = onChanged
        self.onResolvedAll = onResolvedAll
        _viewModel = State(
            initialValue: UncategorizedTransactionsViewModel(cachedSnapshot: cachedSnapshot)
        )
        _selectedDetent = State(
            initialValue: (cachedSnapshot?.transactions.count ?? 0) >= 4 ? .large : .medium
        )
    }

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

                if viewModel.isSelecting || viewModel.canBeginSelection {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(viewModel.isSelecting ? "Done" : "Select") {
                            if viewModel.isSelecting {
                                viewModel.endSelection()
                            } else {
                                viewModel.beginSelection()
                            }
                        }
                        .disabled(viewModel.isCategorizing)
                    }
                }

                if viewModel.isSelecting {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Spacer()
                        Button {
                            isBulkCategoryPickerPresented = true
                        } label: {
                            Group {
                                if viewModel.isBulkCategorizing {
                                    ProgressView()
                                } else {
                                    Text("Categorize")
                                }
                            }
                        }
                        .disabled(!viewModel.canSubmitSelection)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .appSwitcherPrivacyAwareDragIndicator()
        .task {
            await viewModel.loadIfNeeded(month: month, using: appState)
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
            .appSwitcherPrivacyProtected()
        }
        .sheet(isPresented: $isBulkCategoryPickerPresented) {
            TransactionCategorySelectionView(
                categoryGroups: viewModel.categoryGroups,
                selectedCategoryID: nil,
                isLoading: viewModel.isLoading,
                showsUncategorizedOption: false
            ) { option in
                Task {
                    let resolved = await viewModel.categorizeSelection(
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
            .appSwitcherPrivacyProtected()
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
            guard !viewModel.isCategorizing, viewModel.canCategorize(transaction) else {
                return
            }
            if viewModel.isSelecting {
                viewModel.toggleSelection(transaction)
            } else {
                selectedTransaction = SelectedUncategorizedTransaction(transaction: transaction)
            }
        } label: {
            ZStack {
                TransactionRow(
                    transaction: transaction,
                    payeeName: displayPayeeName(for: transaction),
                    categoryNames: displayCategoryNames(for: transaction),
                    isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
                    highlightsIncomeAmounts: appState.settings.greenIncomeTransactionAmountsEnabled,
                    showsBottomSeparator: showsBottomSeparator
                )
                .padding(.leading, viewModel.isSelecting ? 34 : 0)

                if viewModel.isSelecting {
                    HStack {
                        Image(
                            systemName: viewModel.selectedTransactionIDs.contains(transaction.rowID)
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(
                            viewModel.selectedTransactionIDs.contains(transaction.rowID)
                                ? ActualistTheme.accent
                                : ActualistTheme.secondaryText
                        )
                        .padding(.leading, density.rowHorizontalPadding)
                        Spacer()
                    }
                }

                if viewModel.categorizingTransactionID == transaction.rowID {
                    HStack {
                        Spacer()
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
        .disabled(!viewModel.canCategorize(transaction) || viewModel.isCategorizing)
        .animation(.snappy, value: viewModel.isSelecting)
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
