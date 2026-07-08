import SwiftUI
import Observation

struct SpendingTransactionsView: View {
    var body: some View {
        NavigationStack {
            AccountTransactionsView(scope: .spending)
        }
    }
}

enum TransactionFeedScope: Hashable {
    case account(ActualAccount)
    case spending

    var title: String {
        switch self {
        case .account(let account): account.name
        case .spending: "Spending"
        }
    }

    var account: ActualAccount? {
        switch self {
        case .account(let account): account
        case .spending: nil
        }
    }

    var showsBalanceHeader: Bool {
        if case .account = self {
            return true
        }
        return false
    }

    var supportsAccountActions: Bool {
        if case .account = self {
            return true
        }
        return false
    }

    var refreshTargetDescription: String {
        switch self {
        case .account: "this account"
        case .spending: "Spending"
        }
    }
}

struct AccountTransactionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    let scope: TransactionFeedScope

    @FocusState private var isSearchFieldFocused: Bool

    @State private var isLoading = false
    @State private var isLoadingOlder = false
    @State private var isSyncingBank = false
    @State private var isSearchFieldVisible = false
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var searchResults: LoadedAccountTransactions?
    @State private var searchErrorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var isReconcilePresented = false
    @State private var transactionEditorPresentation: TransactionEditorPresentation?
    @State private var deletePresentation: TransactionDeletePresentation?
    @State private var deletingTransactionID: String?
    @State private var deleteIntentHaptic = 0
    @State private var deleteSuccessHaptic = 0

    init(account: ActualAccount) {
        self.scope = .account(account)
    }

    init(scope: TransactionFeedScope) {
        self.scope = scope
    }

    private var budgetID: String? {
        appState.settings.selectedBudgetID
    }

    /// The active transaction repository behind the shared seam.
    private var transactionRepository: (any TransactionRepositoryProtocol)? {
        appState.makeTransactionRepository()
    }

    /// Reactive composed snapshot from the shared store (cached instantly, revalidated in `load`).
    private var loaded: LoadedAccountTransactions? {
        guard let budgetID, let repository = transactionRepository else {
            return nil
        }
        switch scope {
        case .account(let account):
            return repository.cachedAccountTransactions(budgetID: budgetID, accountID: account.id)
        case .spending:
            return repository.cachedSpendingTransactions(budgetID: budgetID)
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
        case .spending:
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

            if scope.showsBalanceHeader {
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
                .disabled(!appState.capabilities.canCreateTransactions)

                if scope.supportsAccountActions {
                    Menu {
                        Button {
                            isReconcilePresented = true
                        } label: {
                            Label("Reconcile", systemImage: "checkmark.seal")
                        }

                        Button {
                            Task { await syncBank() }
                        } label: {
                            Label("Sync Bank", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(isSyncingBank)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .actualistToolbarGlassButton()
                    .accessibilityLabel("Account Actions")
                    .disabled(isSyncingBank || appState.capabilities.isReadOnly)
                }
            }
        }
        .task {
            await load()
        }
        .refreshable { await load() }
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
            case .spending:
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
                prefilledCategoryName: presentation.categoryName
            ) {
                Task { await load() }
            }
                .environment(appState)
        }
        .sheet(isPresented: $isReconcilePresented) {
            if let account = scope.account {
                AccountReconciliationSheet(
                    account: account,
                    currentBalance: balance
                )
                .environment(appState)
            }
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
                .disabled(!canOfferDelete(deletePresentation.transaction))
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            if let deletePresentation {
                Text("Delete \(deletePresentation.payeeName)? Actualist will confirm the server update before refreshing \(scope.refreshTargetDescription).")
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(balanceText)
                .font(ActualistTypography.workScreenAmount(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
            Text("Working Balance")
                .font(ActualistTypography.body(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.horizontal, 16)
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
            // Opens the editor. When a write is unavailable, the editor presents as a detail
            // viewer with mutation controls disabled.
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
                isNew: transaction.id.map { pendingNewTransactionIDs.contains($0) } ?? false,
                showsBottomSeparator: showsBottomSeparator
            )
        }
        .buttonStyle(.plain)
        .disabled(deletingTransactionID == transaction.rowID)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if canOfferDelete(transaction) {
                Button(role: .destructive) {
                    requestDelete(transaction)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(ActualistTheme.danger)
                .disabled(transaction.id == nil || deletingTransactionID != nil)
            }
        }
    }

    /// Whether the delete affordance should be shown for a given row, gated by the capability
    /// matching the row's shape: split parents need `canWriteSplits`, transfers need
    /// `canWriteTransfers`, and simple rows need `canDeleteTransactions`. On a full-write backend
    /// all three are on, so anything is deletable.
    private func canOfferDelete(_ transaction: ActualTransaction) -> Bool {
        if transaction.isParent {
            return appState.capabilities.canWriteSplits
        }
        if let payee = transaction.payee, activeTransferPayeeIDs.contains(payee) {
            return appState.capabilities.canWriteTransfers
        }
        return appState.capabilities.canDeleteTransactions
    }

    private func requestDelete(_ transaction: ActualTransaction) {
        guard canOfferDelete(transaction) else {
            deletePresentation = nil
            errorMessage = offlineMutationMessage
            return
        }

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
        guard canOfferDelete(transaction) else {
            deletePresentation = nil
            errorMessage = offlineMutationMessage
            return
        }

        guard let budgetID else {
            return
        }

        deletingTransactionID = transaction.rowID
        isLoading = true
        errorMessage = nil

        do {
            guard let repository = transactionRepository else {
                return
            }
            // The store reloads the affected account + month, so the reactive snapshot (and the
            // Budget tab) refresh without a second round trip here.
            _ = try await repository.deleteTransactionAndRefresh(
                transaction,
                budgetID: budgetID
            ) {}
            deleteSuccessHaptic += 1
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
        deletingTransactionID = nil
    }

    private var offlineMutationMessage: String {
        "Transaction changes are not enabled for this row."
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

    private func categoryName(for transaction: ActualTransaction) -> String {
        guard let category = transaction.category else {
            if isAccountTransfer(transaction) {
                return "Account Transfer"
            }
            return "Uncategorized"
        }
        return activeCategoryNames[category] ?? "Uncategorized"
    }

    private func isAccountTransfer(_ transaction: ActualTransaction) -> Bool {
        guard let payee = transaction.payee else {
            return false
        }
        return activeTransferPayeeIDs.contains(payee)
    }

    private func categoryNames(for transaction: ActualTransaction) -> [String] {
        if !transaction.subtransactions.isEmpty {
            let names = transaction.subtransactions.map { child in
                categoryName(for: child)
            }
            return names.isEmpty ? ["Split (\(transaction.subtransactions.count))"] : names
        }

        return [categoryName(for: transaction)]
    }

    private func accountName(for transaction: ActualTransaction) -> String? {
        guard case .spending = scope else {
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

    private func load() async {
        guard let budgetID else {
            return
        }

        let hadLoadedSnapshot = loaded != nil
        isLoading = !hadLoadedSnapshot
        errorMessage = nil
        do {
            guard let repository = transactionRepository else {
                isLoading = false
                return
            }
            switch scope {
            case .account(let account):
                try await repository.refreshAccountTransactions(budgetID: budgetID, accountID: account.id)
            case .spending:
                try await repository.refreshSpendingTransactions(budgetID: budgetID)
            }
            isLoading = false

            await appState.refreshLocalFirstData(budgetID: budgetID)
            switch scope {
            case .account(let account):
                try await repository.refreshAccountTransactions(budgetID: budgetID, accountID: account.id)
            case .spending:
                try await repository.refreshSpendingTransactions(budgetID: budgetID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func syncBank() async {
        guard let budgetID,
              let account = scope.account,
              !isSyncingBank,
              appState.capabilities.canBankSync,
              let repository = appState.makeAccountRepository() else {
            return
        }

        isSyncingBank = true
        isLoading = true
        errorMessage = nil
        do {
            _ = try await repository.syncBankAccountAndRefresh(budgetID: budgetID, accountID: account.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        isSyncingBank = false
    }

    private func loadOlder() async {
        guard let budgetID, loaded != nil, !reachedEnd, !isLoading, !isLoadingOlder else {
            return
        }

        isLoadingOlder = true
        errorMessage = nil
        do {
            guard let repository = transactionRepository else {
                return
            }
            switch scope {
            case .account(let account):
                try await repository.loadOlderTransactions(budgetID: budgetID, accountID: account.id)
            case .spending:
                try await repository.loadOlderSpendingTransactions(budgetID: budgetID)
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
            guard let repository = transactionRepository else {
                isSearching = false
                return
            }
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

        guard case .spending = scope else {
            return nil
        }

        return PrivacyDisplay.name(for: .account, seed: transaction.account)
    }
}
