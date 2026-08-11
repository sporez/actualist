import SwiftUI

struct AccountTransactionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @Environment(\.dismiss) private var dismiss
    let scope: TransactionFeedScope
    let onChanged: () -> Void
    let categoryCarryoverIsEnabled: Bool?
    let categoryCarryoverIsUpdating: Bool
    let canEditCategoryCarryover: Bool
    let categoryCarryoverErrorMessage: String?
    let onCategoryCarryoverChanged: (Bool) -> Void

    @FocusState private var isSearchFieldFocused: Bool

    @State private var isLoading = true
    @State private var isLoadingOlder = false
    @State private var isSearchFieldVisible = false
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var searchResults: LoadedAccountTransactions?
    @State private var searchErrorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var transactionEditorPresentation: TransactionEditorPresentation?
    @State private var deletePresentation: TransactionDeletePresentation?
    @State private var deletingTransactionID: String?
    @State private var deleteIntentHaptic = 0
    @State private var deleteSuccessHaptic = 0

    init(account: ActualAccount) {
        self.scope = .account(account)
        self.onChanged = {}
        self.categoryCarryoverIsEnabled = nil
        self.categoryCarryoverIsUpdating = false
        self.canEditCategoryCarryover = false
        self.categoryCarryoverErrorMessage = nil
        self.onCategoryCarryoverChanged = { _ in }
    }

    init(
        scope: TransactionFeedScope,
        onChanged: @escaping () -> Void = {},
        categoryCarryoverIsEnabled: Bool? = nil,
        categoryCarryoverIsUpdating: Bool = false,
        canEditCategoryCarryover: Bool = false,
        categoryCarryoverErrorMessage: String? = nil,
        onCategoryCarryoverChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.scope = scope
        self.onChanged = onChanged
        self.categoryCarryoverIsEnabled = categoryCarryoverIsEnabled
        self.categoryCarryoverIsUpdating = categoryCarryoverIsUpdating
        self.canEditCategoryCarryover = canEditCategoryCarryover
        self.categoryCarryoverErrorMessage = categoryCarryoverErrorMessage
        self.onCategoryCarryoverChanged = onCategoryCarryoverChanged
    }

    private var budgetID: String? {
        appState.settings.selectedBudgetID
    }

    private var transactionRepository: any TransactionRepositoryProtocol {
        appState.transactionRepository
    }

    private var loaded: LoadedAccountTransactions? {
        guard let budgetID else {
            return nil
        }
        let repository = transactionRepository
        switch scope {
        case .account(let account):
            return repository.cachedAccountTransactions(budgetID: budgetID, accountID: account.id)
        case .spending:
            return repository.cachedSpendingTransactions(budgetID: budgetID)
        case .category(let details):
            return repository.cachedCategoryTransactions(
                budgetID: budgetID,
                categoryID: details.category.id,
                month: details.month
            )
        }
    }

    private var transactions: [ActualTransaction] {
        loaded?.transactions ?? []
    }

    private var balance: Int? {
        loaded?.balance
    }

    private var categoryNames: [String: String] {
        loaded?.categoryNames ?? [:]
    }

    private var accountNames: [String: String] {
        loaded?.accountNames ?? [:]
    }

    private var payeeNames: [String: String] {
        loaded?.payeeNames ?? [:]
    }

    private var transferPayeeIDs: Set<String> {
        loaded?.transferPayeeIDs ?? []
    }

    private var reachedEnd: Bool {
        loaded?.reachedEnd ?? false
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

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearchActive: Bool {
        !trimmedSearchText.isEmpty
    }

    private var displayedTransactions: [ActualTransaction] {
        guard isSearchActive else {
            return transactions
        }
        if let searchResults {
            return searchResults.transactions
        }
        return locallyFilteredTransactions
    }

    private var locallyFilteredTransactions: [ActualTransaction] {
        transactions.filter { transaction in
            searchTextMatches(payeeName(for: transaction))
                || categoryNames(for: transaction).contains(where: searchTextMatches)
                || searchTextMatches(accountName(for: transaction))
                || transaction.subtransactions.contains { child in
                    searchTextMatches(child.notes)
                }
                || searchTextMatches(transaction.importedPayee)
                || searchTextMatches(transaction.notes)
        }
    }

    private var displayedGroups: [TransactionDateGroup] {
        TransactionGrouping.grouped(displayedTransactions)
    }

    private var activeCategoryNames: [String: String] {
        searchResults?.categoryNames ?? categoryNames
    }

    private var activeAccountNames: [String: String] {
        searchResults?.accountNames ?? accountNames
    }

    private var activePayeeNames: [String: String] {
        searchResults?.payeeNames ?? payeeNames
    }

    private var activeTransferPayeeIDs: Set<String> {
        searchResults?.transferPayeeIDs ?? transferPayeeIDs
    }

    private var activeTransferAccountIDsByPayeeID: [String: String] {
        searchResults?.transferAccountIDsByPayeeID
            ?? loaded?.transferAccountIDsByPayeeID
            ?? [:]
    }

    private var activeOffBudgetAccountIDs: Set<String> {
        searchResults?.offBudgetAccountIDs ?? loaded?.offBudgetAccountIDs ?? []
    }

    var body: some View {
        List {
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
                    header
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }

            transactionList

            if isSearchActive {
                searchFooter
            } else {
                olderTransactionsFooter
            }

            if isLoading {
                ProgressView("Loading transactions")
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if let errorMessage {
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
        .navigationTitle(scopeTitle)
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
                    transactionEditorPresentation = .create
                } label: {
                    Image(systemName: "plus")
                }
                .actualistToolbarGlassButton()
                .accessibilityLabel("Add Transaction")
            }
        }
        .task {
            await loadLocal()
        }
        .refreshable { await refresh() }
        .onChange(of: appState.localDataRevision) {
            Task { await loadLocal() }
        }
        .onChange(of: searchText) { _, updated in
            scheduleSearch(updated)
        }
        .onDisappear {
            searchTask?.cancel()
            guard let budgetID else {
                return
            }
            switch scope {
            case .account(let account):
                appState.clearPendingNewTransactionIDs(budgetID: budgetID, accountID: account.id)
            case .spending, .category:
                appState.clearPendingNewTransactionIDs(budgetID: budgetID)
            }
        }
        .sensoryFeedback(.selection, trigger: deleteIntentHaptic)
        .sensoryFeedback(.success, trigger: deleteSuccessHaptic)
        .sheet(item: $transactionEditorPresentation) { presentation in
            TransactionEditorView(
                prefilledAccount: scope.account,
                editingTransaction: presentation.transaction,
                prefilledPayeeName: presentation.payeeName,
                prefilledCategoryName: presentation.categoryName ?? scope.prefilledCategoryName
            ) {
                Task { await loadLocal() }
            }
                .environment(appState)
                .appSwitcherPrivacyProtected()
        }
        .confirmationDialog(
            "Delete Transaction?",
            isPresented: Binding(
                get: { deletePresentation != nil },
                set: { isPresented in
                    if !isPresented {
                        deletePresentation = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let deletePresentation {
                Button("Delete Transaction", role: .destructive) {
                    Task { await delete(deletePresentation.transaction) }
                }
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            if let deletePresentation {
                Text("Delete \(deletePresentation.payeeName)? Actualist will confirm the server update before refreshing \(scope.refreshTargetDescription).")
            }
        }
    }

    private var header: some View {
        Group {
            if let details = scope.categoryDetails {
                categorySummary(details)
            } else {
                VStack(spacing: 6) {
                    Text(balanceText)
                        .font(ActualistTypography.workScreenAmount(for: density))
                        .foregroundStyle(ActualistTheme.primaryText)
                    Text("Working Balance")
                        .font(ActualistTypography.body(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.horizontal, 16)
    }

    private func categorySummary(_ details: CategoryMonthDetails) -> some View {
        VStack(spacing: 0) {
            Text(details.monthTitle)
                .font(ActualistTypography.sectionTitle(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)

            categorySummaryRow(label: "Budgeted", amount: details.budgetedAmount)
            Divider().overlay(ActualistTheme.separator)
            categorySummaryRow(label: "Spent", amount: details.spentAmount)
            Divider().overlay(ActualistTheme.separator)
            categorySummaryRow(
                label: "Remaining",
                amount: details.remainingAmount,
                foreground: remainingForeground(details.remainingAmount)
            )

            if let categoryCarryoverIsEnabled {
                Divider().overlay(ActualistTheme.separator)

                categoryCarryoverRow(isEnabled: categoryCarryoverIsEnabled)
            }

            if let categoryCarryoverErrorMessage {
                Text(categoryCarryoverErrorMessage)
                    .font(ActualistTypography.rowLabel(for: density))
                    .foregroundStyle(ActualistTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func categoryCarryoverRow(isEnabled: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Rollover Overspending")
                    .font(ActualistTypography.body(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)

                Text("Carry this category’s negative balance into following months.")
                    .font(ActualistTypography.rowLabel(for: density))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if categoryCarryoverIsUpdating {
                ProgressView()
                    .controlSize(.small)
                    .tint(ActualistTheme.accent)
            }

            Toggle(
                "Rollover Overspending",
                isOn: Binding(
                    get: { isEnabled },
                    set: onCategoryCarryoverChanged
                )
            )
            .labelsHidden()
            .tint(ActualistTheme.accent)
            .disabled(!canEditCategoryCarryover || categoryCarryoverIsUpdating)
            .accessibilityValue(isEnabled ? "On" : "Off")
        }
        .padding(.vertical, 10)
    }

    private func categorySummaryRow(
        label: String,
        amount: Int,
        foreground: Color = ActualistTheme.primaryText
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(ActualistTypography.body(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
            Spacer()
            Text(summaryAmountText(amount, label: label))
                .font(ActualistTypography.rowValue(for: density))
                .foregroundStyle(foreground)
        }
        .padding(.vertical, 10)
    }

    private func summaryAmountText(_ amount: Int, label: String) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return amount.actualMoney.formatted()
        }
        return PrivacyDisplay.money(
            amount,
            seed: "category-summary-\(scope.categoryDetails?.id ?? label)-\(label)",
            maximumDollars: 2_500
        )
    }

    private func remainingForeground(_ amount: Int) -> Color {
        if amount < 0 { return ActualistTheme.danger }
        if amount == 0 { return ActualistTheme.secondaryText }
        return ActualistTheme.positive
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(ActualistTheme.secondaryText)
                .accessibilityHidden(true)

            TextField("Search Transactions", text: $searchText)
                .focused($isSearchFieldFocused)
                .font(ActualistTypography.body(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .tint(ActualistTheme.accent)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                if isSearchActive {
                    searchText = ""
                    searchResults = nil
                    searchErrorMessage = nil
                    isSearching = false
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
            .accessibilityLabel(isSearchActive ? "Clear Search" : "Close Search")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(ActualistTheme.control, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var transactionList: some View {
        ForEach(displayedGroups, id: \.date) { group in
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

            ForEach(Array(group.transactions.enumerated()), id: \.element.rowID) { index, transaction in
                transactionButton(
                    for: transaction,
                    showsBottomSeparator: index < group.transactions.count - 1
                )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(ActualistTheme.surface)
            }
        }
    }

    @ViewBuilder
    private var searchFooter: some View {
        Group {
            if isSearching {
                ProgressView("Searching transactions")
                    .font(ActualistTypography.rowBadge(for: density))
            } else if let searchErrorMessage {
                Text(searchErrorMessage)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.danger)
            } else if displayedTransactions.isEmpty {
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
    private var olderTransactionsFooter: some View {
        if loaded != nil {
            Group {
                if reachedEnd {
                    Text("Beginning of history")
                        .font(ActualistTypography.rowBadge(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                } else if isLoadingOlder {
                    ProgressView("Loading older transactions")
                        .font(ActualistTypography.rowBadge(for: density))
                } else {
                    Button {
                        Task { await loadOlder() }
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
                Task { await loadOlder() }
            }
        }
    }

    private func transactionButton(
        for transaction: ActualTransaction,
        showsBottomSeparator: Bool
    ) -> some View {
        Button {
            transactionEditorPresentation = .edit(
                transaction,
                payeeName: payeeName(for: transaction),
                categoryName: categoryNames(for: transaction).first ?? "Uncategorized"
            )
        } label: {
            TransactionRow(
                transaction: transaction,
                payeeName: displayPayeeName(for: transaction),
                categoryNames: displayCategoryNames(for: transaction),
                accountName: displayAccountName(for: transaction),
                isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
                highlightsIncomeAmounts: appState.settings.greenIncomeTransactionAmountsEnabled,
                isNew: transaction.id.map { pendingNewTransactionIDs.contains($0) } ?? false,
                showsBottomSeparator: showsBottomSeparator
            )
        }
        .buttonStyle(.plain)
        .disabled(deletingTransactionID == transaction.rowID)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                requestDelete(transaction)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(ActualistTheme.danger)
            .disabled(transaction.id == nil || deletingTransactionID != nil)
        }
    }

    private func requestDelete(_ transaction: ActualTransaction) {
        guard transaction.id != nil else {
            errorMessage = "This transaction cannot be deleted because it is missing its transaction ID."
            return
        }

        deleteIntentHaptic += 1
        deletePresentation = TransactionDeletePresentation(
            transaction: transaction,
            payeeName: payeeName(for: transaction)
        )
    }

    private func delete(_ transaction: ActualTransaction) async {
        guard let budgetID else {
            return
        }

        deletingTransactionID = transaction.rowID
        isLoading = true
        errorMessage = nil

        do {
            let repository = transactionRepository
            _ = try await repository.deleteTransactionAndRefresh(
                transaction,
                budgetID: budgetID
            ) {}
            if case .category(let details) = scope {
                try await repository.refreshCategoryTransactions(
                    budgetID: budgetID,
                    categoryID: details.category.id,
                    month: details.month
                )
                onChanged()
            }
            deleteSuccessHaptic += 1
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
        deletingTransactionID = nil
    }

    private func payeeName(for transaction: ActualTransaction) -> String {
        if let payeeName = transaction.payeeName, !payeeName.isEmpty {
            return payeeName
        }
        if let payee = transaction.payee, let name = activePayeeNames[payee] {
            return name
        }
        if let importedPayee = transaction.importedPayee, !importedPayee.isEmpty {
            return importedPayee
        }
        return "Unknown Payee"
    }

    private func categoryNames(for transaction: ActualTransaction) -> [String] {
        TransactionCategoryPresentation.names(
            for: transaction,
            categoryNames: activeCategoryNames,
            transferPayeeIDs: activeTransferPayeeIDs,
            transferAccountIDsByPayeeID: activeTransferAccountIDsByPayeeID,
            offBudgetAccountIDs: activeOffBudgetAccountIDs
        )
    }

    private func accountName(for transaction: ActualTransaction) -> String? {
        guard scope.showsAccountNames else {
            return nil
        }

        let name = activeAccountNames[transaction.account]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : "Unknown Account"
    }

    private func searchTextMatches(_ value: String?) -> Bool {
        guard let value, !trimmedSearchText.isEmpty else {
            return false
        }
        return value.localizedCaseInsensitiveContains(trimmedSearchText)
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
        searchTask?.cancel()
        isSearching = false
        searchText = ""
        searchResults = nil
        searchErrorMessage = nil
        isSearchFieldFocused = false

        withAnimation(.snappy(duration: 0.2)) {
            isSearchFieldVisible = false
        }
    }

    private func loadLocal() async {
        guard let budgetID else {
            isLoading = false
            return
        }

        let hadLoadedSnapshot = loaded != nil
        isLoading = !hadLoadedSnapshot
        errorMessage = nil
        do {
            let repository = transactionRepository
            switch scope {
            case .account(let account):
                try await repository.refreshAccountTransactions(budgetID: budgetID, accountID: account.id)
            case .spending:
                try await repository.refreshSpendingTransactions(budgetID: budgetID)
            case .category(let details):
                try await repository.refreshCategoryTransactions(
                    budgetID: budgetID,
                    categoryID: details.category.id,
                    month: details.month
                )
            }
            isLoading = false
        } catch {
            errorMessage = loaded == nil ? error.localizedDescription : nil
        }
        isLoading = false
    }

    private func refresh() async {
        guard let budgetID else {
            return
        }
        _ = await appState.refreshLocalFirstData(budgetID: budgetID, force: true)
        await loadLocal()
        onChanged()
    }

    private func loadOlder() async {
        guard let budgetID, loaded != nil, !reachedEnd, !isLoading, !isLoadingOlder else {
            return
        }

        isLoadingOlder = true
        errorMessage = nil
        do {
            let repository = transactionRepository
            switch scope {
            case .account(let account):
                try await repository.loadOlderTransactions(budgetID: budgetID, accountID: account.id)
            case .spending:
                try await repository.loadOlderSpendingTransactions(budgetID: budgetID)
            case .category:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingOlder = false
    }

    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        searchErrorMessage = nil
        searchResults = nil

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            isSearching = false
            return
        }

        if case .category = scope {
            // Category-month feeds are complete local snapshots.
            isSearching = false
            return
        }

        searchTask = Task {
            isSearching = true
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else {
                isSearching = false
                return
            }
            await search(trimmedQuery)
        }
    }

    private func search(_ query: String) async {
        guard let budgetID else {
            isSearching = false
            return
        }

        do {
            let repository = transactionRepository
            let results: LoadedAccountTransactions
            switch scope {
            case .account(let account):
                results = try await repository.searchAccountTransactions(
                    budgetID: budgetID,
                    accountID: account.id,
                    query: query,
                    limit: 50,
                    offset: 0
                )
            case .spending:
                results = try await repository.searchSpendingTransactions(
                    budgetID: budgetID,
                    query: query,
                    limit: 50,
                    offset: 0
                )
            case .category:
                isSearching = false
                return
            }
            guard !Task.isCancelled, query == trimmedSearchText else {
                return
            }
            searchResults = results
        } catch {
            guard !Task.isCancelled else {
                return
            }
            searchErrorMessage = error.localizedDescription
        }
        isSearching = false
    }

    private var scopeTitle: String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return scope.title
        }

        switch scope {
        case .account(let account):
            return PrivacyDisplay.name(for: .account, seed: account.id)
        case .spending:
            return scope.title
        case .category(let details):
            return PrivacyDisplay.name(for: .category, seed: details.category.id)
        }
    }

    private var balanceText: String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return (balance ?? 0).actualMoney.formatted()
        }

        let seed = scope.account.map { "account-header-\($0.id)" } ?? "spending-header"
        return PrivacyDisplay.money(balance, seed: seed, maximumDollars: 15_000)
    }

    private func displayPayeeName(for transaction: ActualTransaction) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return payeeName(for: transaction)
        }

        return PrivacyDisplay.name(for: .payee, seed: "payee-\(transaction.rowID)")
    }

    private func displayCategoryNames(for transaction: ActualTransaction) -> [String] {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return categoryNames(for: transaction)
        }

        if !transaction.subtransactions.isEmpty {
            return transaction.subtransactions.map { child in
                PrivacyDisplay.name(for: .category, seed: "category-\(child.rowID)")
            }
        }

        return [PrivacyDisplay.name(for: .category, seed: "category-\(transaction.rowID)")]
    }

    private func displayAccountName(for transaction: ActualTransaction) -> String? {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return accountName(for: transaction)
        }

        guard scope.showsAccountNames else {
            return nil
        }

        return PrivacyDisplay.name(for: .account, seed: transaction.account)
    }
}
