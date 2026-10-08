import SwiftUI

struct UncategorizedTransactionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewModel = UncategorizedTransactionsViewModel()
    @State private var selectedTransaction: SelectedUncategorizedTransaction?
    @State private var isBulkCategoryPickerPresented = false
    @State private var selectedDetent: PresentationDetent = .medium

    let month: String
    let onChanged: @MainActor () -> Void
    let onResolvedAll: @MainActor () -> Void

    init(
        month: String,
        cachedSnapshot: LoadedUncategorizedTransactions?,
        onChanged: @escaping @MainActor () -> Void,
        onResolvedAll: @escaping @MainActor () -> Void
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ReviewSheetHeader(title: "Uncategorized")
                content
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await viewModel.refresh(month: month, using: appState)
        }
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .reviewSheetBottomBar {
            if viewModel.isSelecting {
                ReviewSheetSecondaryButton(title: "Done", role: nil) {
                    viewModel.endSelection()
                }
                .disabled(viewModel.isCategorizing)
                .accessibilityIdentifier("uncategorized-select-done")

                ReviewSheetPrimaryButton {
                    isBulkCategoryPickerPresented = true
                } label: {
                    if viewModel.isBulkCategorizing {
                        ProgressView()
                    } else {
                        Text("Categorize")
                    }
                }
                .disabled(!viewModel.canSubmitSelection)
                .accessibilityIdentifier("uncategorized-categorize")
            } else {
                ReviewSheetSecondaryButton(title: "Close") { dismiss() }
                    .accessibilityIdentifier("uncategorized-close")

                if viewModel.canBeginSelection {
                    ReviewSheetPrimaryButton {
                        viewModel.beginSelection()
                    } label: {
                        Text("Select")
                    }
                    .disabled(viewModel.isCategorizing)
                    .accessibilityIdentifier("uncategorized-select-done")
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large], selection: $selectedDetent)
        .appSwitcherPrivacyAwareDragIndicator()
        .presentationBackground(ActualistTheme.background)
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
                    handle(await viewModel.categorize(
                        selection.transaction,
                        as: option,
                        month: month,
                        using: appState
                    ))
                }
            }
            .appSwitcherPrivacyProtected(using: appState)
        }
        .sheet(isPresented: $isBulkCategoryPickerPresented) {
            TransactionCategorySelectionView(
                categoryGroups: viewModel.categoryGroups,
                selectedCategoryID: nil,
                isLoading: viewModel.isLoading,
                showsUncategorizedOption: false
            ) { option in
                Task {
                    handle(await viewModel.categorizeSelection(
                        as: option,
                        month: month,
                        using: appState
                    ))
                }
            }
            .appSwitcherPrivacyProtected(using: appState)
        }
        .confirmationDialog(
            viewModel.reconciledCategorization?.presentation?.title ?? "Reconciled Transaction",
            isPresented: reconciledCategorizationBinding,
            titleVisibility: .visible,
            presenting: viewModel.reconciledCategorization
        ) { pending in
            // `pending` is captured here: SwiftUI clears the binding as the
            // dialog dismisses, before this task would otherwise run.
            Button(pending.presentation?.confirmationTitle ?? "Categorize") {
                Task {
                    handle(await viewModel.confirmReconciledCategorization(pending, using: appState))
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.dismissReconciledCategorization()
            }
        } message: { pending in
            Text(pending.presentation?.message ?? "")
        }
    }

    private var reconciledCategorizationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.reconciledCategorization != nil },
            set: { presented in
                if !presented { viewModel.dismissReconciledCategorization() }
            }
        )
    }

    private func handle(_ resolved: UncategorizedTransactionsViewModel.CategorizationResult) {
        if resolved.didChange {
            onChanged()
        }
        if resolved.resolvedAll {
            onResolvedAll()
            dismiss()
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading, viewModel.transactions.isEmpty {
            HStack {
                ProgressView()
                Text("Loading transactions")
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .actualistReviewCard()
        } else if viewModel.transactions.isEmpty, let errorMessage = viewModel.errorMessage {
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
            .actualistReviewCard()
        } else if viewModel.transactions.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(ActualistTheme.positive)
                Text("No uncategorized transactions")
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
            }
            .frame(maxWidth: .infinity)
            .actualistReviewCard()
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
                            .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(ActualistTheme.separator, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                    semantics: displaySemantics(for: transaction),
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

    private func displaySemantics(for transaction: ActualTransaction) -> TransactionRowSemantics {
        viewModel.rowSemantics(
            for: transaction,
            privacyEnabled: appState.settings.randomizedDisplayValuesEnabled
        )
    }
}

private struct SelectedUncategorizedTransaction: Identifiable {
    let transaction: ActualTransaction

    var id: String {
        transaction.rowID
    }
}
