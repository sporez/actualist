import SwiftUI

struct AccountTransactionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @Environment(\.dismiss) private var dismiss
    let scope: TransactionFeedScope
    let onChanged: () -> Void
    let categoryCarryoverIsEnabled: Bool?
    let categoryNoteText: String?
    let categoryCarryoverIsUpdating: Bool
    let canEditCategoryCarryover: Bool
    let categoryCarryoverErrorMessage: String?
    let onCategoryCarryoverChanged: (Bool) -> Void

    @FocusState private var isSearchFieldFocused: Bool
    @State private var isSearchFieldVisible = false
    @State private var viewModel: AccountTransactionsViewModel

    init(account: ActualAccount) {
        self.scope = .account(account)
        self.onChanged = {}
        self.categoryCarryoverIsEnabled = nil
        self.categoryNoteText = nil
        self.categoryCarryoverIsUpdating = false
        self.canEditCategoryCarryover = false
        self.categoryCarryoverErrorMessage = nil
        self.onCategoryCarryoverChanged = { _ in }
        _viewModel = State(initialValue: AccountTransactionsViewModel(scope: .account(account)))
    }

    init(
        scope: TransactionFeedScope,
        onChanged: @escaping () -> Void = {},
        categoryCarryoverIsEnabled: Bool? = nil,
        categoryNoteText: String? = nil,
        categoryCarryoverIsUpdating: Bool = false,
        canEditCategoryCarryover: Bool = false,
        categoryCarryoverErrorMessage: String? = nil,
        onCategoryCarryoverChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.scope = scope
        self.onChanged = onChanged
        self.categoryCarryoverIsEnabled = categoryCarryoverIsEnabled
        self.categoryNoteText = categoryNoteText
        self.categoryCarryoverIsUpdating = categoryCarryoverIsUpdating
        self.canEditCategoryCarryover = canEditCategoryCarryover
        self.categoryCarryoverErrorMessage = categoryCarryoverErrorMessage
        self.onCategoryCarryoverChanged = onCategoryCarryoverChanged
        _viewModel = State(initialValue: AccountTransactionsViewModel(scope: scope))
    }

    private var budgetID: String? {
        appState.settings.selectedBudgetID
    }

    private var budgetCurrency: BudgetCurrency {
        guard let budgetID else { return .usd }
        return appState.localFirstStore.budgetCurrency(budgetID: budgetID)
    }

    private var transactionRepository: any TransactionRepositoryProtocol {
        appState.transactionRepository
    }

    private var pendingNewTransactionIDs: Set<String> {
        guard let budgetID else {
            return []
        }
        switch scope {
        case .account(let account):
            return appState.pendingNewTransactionIDs(budgetID: budgetID, accountID: account.id)
        case .spending, .category:
            return appState.pendingNewTransactionIDs(budgetID: budgetID)
        }
    }

    var body: some View {
        let displayState = viewModel.displayState(
            budgetID: budgetID,
            repository: transactionRepository,
            pendingNewTransactionIDs: pendingNewTransactionIDs,
            privacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
            currency: budgetCurrency
        )

        return List {
            if isSearchFieldVisible {
                Section {
                    searchBar
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if scope.showsSummaryHeader {
                Section {
                    header(displayState)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }

            transactionList(displayState)

            if viewModel.isSearchActive {
                searchFooter(displayState)
            } else {
                olderTransactionsFooter(displayState)
            }

            if viewModel.isLoading {
                ProgressView("Loading transactions")
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.danger)
                    .padding(.horizontal, 16)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .navigationTitle(displayState.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if scope.categoryDetails != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close Category Details")
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showSearch()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .actualistToolbarGlassButton()
                .accessibilityLabel("Search Transactions")

                Button {
                    viewModel.showCreateEditor()
                } label: {
                    Image(systemName: "plus")
                }
                .actualistToolbarGlassButton()
                .accessibilityLabel("Add Transaction")
            }
        }
        .task {
            await viewModel.loadLocal(budgetID: budgetID, repository: transactionRepository)
        }
        .refreshable {
            await viewModel.refresh(
                budgetID: budgetID,
                repository: transactionRepository,
                sync: {
                    guard let budgetID else { return }
                    _ = await appState.refreshLocalFirstData(budgetID: budgetID, force: true)
                },
                onChanged: onChanged
            )
        }
        .onChange(of: appState.localDataRevision) {
            Task {
                await viewModel.loadLocal(budgetID: budgetID, repository: transactionRepository)
            }
        }
        .onChange(of: viewModel.searchText) {
            viewModel.scheduleSearch(budgetID: budgetID, repository: transactionRepository)
        }
        .onDisappear {
            viewModel.cancelSearch()
            viewModel.clearPendingNewTransactions(budgetID: budgetID) { budgetID, accountID in
                if let accountID {
                    appState.clearPendingNewTransactionIDs(budgetID: budgetID, accountID: accountID)
                } else {
                    appState.clearPendingNewTransactionIDs(budgetID: budgetID)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: viewModel.deleteIntentFeedback)
        .sensoryFeedback(.success, trigger: viewModel.deleteSuccessFeedback)
        .sheet(item: editorPresentationBinding) { presentation in
            TransactionEditorView(
                prefilledAccount: scope.account,
                editingTransaction: presentation.transaction,
                prefilledPayeeName: presentation.payeeName,
                prefilledCategoryName: presentation.categoryName ?? scope.prefilledCategoryName
            ) {
                Task {
                    await viewModel.loadLocal(budgetID: budgetID, repository: transactionRepository)
                }
            }
                .environment(appState)
                .appSwitcherPrivacyProtected()
        }
    }

    private var editorPresentationBinding: Binding<TransactionEditorPresentation?> {
        Binding(
            get: { viewModel.transactionEditorPresentation },
            set: { viewModel.transactionEditorPresentation = $0 }
        )
    }

    private var deletePresentationBinding: Binding<TransactionDeletePresentation?> {
        Binding(
            get: { viewModel.deletePresentation },
            set: { viewModel.deletePresentation = $0 }
        )
    }

    private func header(_ displayState: AccountTransactionsDisplayState) -> some View {
        AccountTransactionsSummaryView(
            scope: scope,
            displayState: displayState,
            categoryCarryoverIsEnabled: categoryCarryoverIsEnabled,
            categoryNoteText: categoryNoteText,
            categoryCarryoverIsUpdating: categoryCarryoverIsUpdating,
            canEditCategoryCarryover: canEditCategoryCarryover,
            categoryCarryoverErrorMessage: categoryCarryoverErrorMessage,
            onCategoryCarryoverChanged: onCategoryCarryoverChanged
        )
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(ActualistTheme.secondaryText)
                .accessibilityHidden(true)

            TextField(
                "Search Transactions",
                text: Binding(
                    get: { viewModel.searchText },
                    set: { viewModel.searchText = $0 }
                )
            )
                .focused($isSearchFieldFocused)
                .font(ActualistTypography.body(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .tint(ActualistTheme.accent)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                if viewModel.isSearchActive {
                    viewModel.clearSearch()
                    isSearchFieldFocused = true
                } else {
                    hideSearch()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isSearchActive ? "Clear Search" : "Close Search")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(ActualistTheme.control, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func transactionList(_ displayState: AccountTransactionsDisplayState) -> some View {
        ForEach(displayState.groups) { group in
            Text(group.title)
                .font(ActualistTypography.sectionTitle(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .textCase(nil)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .padding(.horizontal, density.rowHorizontalPadding)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                transactionButton(
                    for: row,
                    showsBottomSeparator: index < group.rows.count - 1
                )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(ActualistTheme.surface)
            }
        }
    }

    @ViewBuilder
    private func searchFooter(_ displayState: AccountTransactionsDisplayState) -> some View {
        Group {
            if viewModel.isSearching {
                ProgressView("Searching transactions")
                    .font(ActualistTypography.rowBadge(for: density))
            } else if let searchErrorMessage = viewModel.searchErrorMessage {
                Text(searchErrorMessage)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.danger)
            } else if displayState.transactionCount == 0 {
                Text("No matching transactions")
                    .font(ActualistTypography.rowBadge(for: density))
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func olderTransactionsFooter(_ displayState: AccountTransactionsDisplayState) -> some View {
        if displayState.hasLoadedSnapshot {
            Group {
                if displayState.reachedEnd {
                    Text("Beginning of history")
                        .font(ActualistTypography.rowBadge(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                } else if viewModel.isLoadingOlder {
                    ProgressView("Loading older transactions")
                        .font(ActualistTypography.rowBadge(for: density))
                } else {
                    Button {
                        Task {
                            await viewModel.loadOlder(
                                budgetID: budgetID,
                                repository: transactionRepository
                            )
                        }
                    } label: {
                        Label("Load older transactions", systemImage: "clock.arrow.circlepath")
                            .font(ActualistTypography.control(for: density))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ActualistTheme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .onAppear {
                Task {
                    await viewModel.loadOlder(
                        budgetID: budgetID,
                        repository: transactionRepository
                    )
                }
            }
        }
    }

    private func transactionButton(
        for row: AccountTransactionRowPresentation,
        showsBottomSeparator: Bool
    ) -> some View {
        Button {
            viewModel.showEditor(
                for: row.transaction,
                budgetID: budgetID,
                repository: transactionRepository
            )
        } label: {
            TransactionRow(
                transaction: row.transaction,
                payeeName: row.payeeName,
                categoryNames: row.categoryNames,
                accountName: row.accountName,
                isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
                highlightsIncomeAmounts: appState.settings.greenIncomeTransactionAmountsEnabled,
                isNew: row.isNew,
                showsBottomSeparator: showsBottomSeparator
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.deletingTransactionID == row.transaction.rowID)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                viewModel.requestDelete(
                    row.transaction,
                    budgetID: budgetID,
                    repository: transactionRepository
                )
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(ActualistTheme.danger)
            .disabled(row.transaction.id == nil || viewModel.deletingTransactionID != nil)
        }
        .confirmationDialog(
            "Delete Transaction?",
            isPresented: deletePresentationBinding.isPresented(matching: row.id),
            titleVisibility: .visible
        ) {
            Button("Delete Transaction", role: .destructive) {
                Task {
                    await viewModel.delete(
                        row.transaction,
                        budgetID: budgetID,
                        repository: transactionRepository,
                        onChanged: onChanged
                    )
                }
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \(row.payeeName)? Actualist will confirm the server update before refreshing \(scope.refreshTargetDescription).")
        }
    }

    private func showSearch() {
        withAnimation(.snappy(duration: 0.22)) {
            isSearchFieldVisible = true
        }

        Task { @MainActor in
            await Task.yield()
            guard isSearchFieldVisible else {
                return
            }
            isSearchFieldFocused = true
        }
    }

    private func hideSearch() {
        viewModel.clearSearch()
        isSearchFieldFocused = false

        withAnimation(.snappy(duration: 0.2)) {
            isSearchFieldVisible = false
        }
    }
}
