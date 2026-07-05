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

    /// The active read backend (REST data store or local-first store) behind the shared seam.
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
            if let budgetID, let account = scope.account {
                appState.clearPendingNewTransactionIDs(budgetID: budgetID, accountID: account.id)
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
            // Opens the editor. When read-only (local-first / offline REST) the editor
            // presents as a detail viewer with all mutation controls disabled.
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
            errorMessage = "This transaction cannot be deleted because the API did not provide its transaction ID."
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
            // The store invalidates and refetches the affected account + month, so the reactive
            // snapshot (and the Budget tab) refresh without a second round trip here.
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
        "Server is offline. Transaction changes are read-only until it reconnects."
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

        isLoading = true
        errorMessage = nil
        do {
            guard let repository = transactionRepository else {
                return
            }
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

struct TransactionEditorPresentation: Identifiable, Hashable {
    let id: String
    let transaction: ActualTransaction?
    let payeeName: String?
    let categoryName: String?

    static var create: TransactionEditorPresentation {
        TransactionEditorPresentation(
            id: "create",
            transaction: nil,
            payeeName: nil,
            categoryName: nil
        )
    }

    static func edit(
        _ transaction: ActualTransaction,
        payeeName: String,
        categoryName: String
    ) -> TransactionEditorPresentation {
        TransactionEditorPresentation(
            id: "edit-\(transaction.rowID)",
            transaction: transaction,
            payeeName: payeeName,
            categoryName: categoryName
        )
    }
}

struct TransactionDeletePresentation: Identifiable, Hashable {
    let transaction: ActualTransaction
    let payeeName: String

    var id: String {
        transaction.rowID
    }
}

enum AccountReconciliationSubmissionState: Equatable {
    case draft
    case submitting
    case reconciled(APIAccountReconciliationResult)
    case mismatch(APIAccountReconciliationResult)
    case failed(String)
}

@MainActor
@Observable
final class AccountReconciliationViewModel {
    var statementBalanceText: String
    var submissionState: AccountReconciliationSubmissionState = .draft

    init(currentBalance: Int?) {
        statementBalanceText = Self.formattedInput(cents: currentBalance ?? 0)
    }

    var canSubmit: Bool {
        statementBalanceMinorUnits != nil && !isSubmitting
    }

    var isSubmitting: Bool {
        if case .submitting = submissionState {
            return true
        }
        return false
    }

    var submitTitle: String {
        isSubmitting ? "Reconciling" : "Reconcile"
    }

    var statementBalanceMinorUnits: Int? {
        Self.minorUnits(from: statementBalanceText)
    }

    var resultTitle: String? {
        switch submissionState {
        case .draft, .submitting:
            nil
        case .reconciled:
            "Reconciled"
        case .mismatch:
            "Balances Do Not Match"
        case .failed:
            "Reconcile Failed"
        }
    }

    var resultMessage: String? {
        switch submissionState {
        case .draft, .submitting:
            return nil
        case .reconciled(let result):
            let count = result.updated.count
            return count == 1 ? "Marked 1 transaction reconciled." : "Marked \(count) transactions reconciled."
        case .mismatch(let result):
            return "Actual cleared balance is \(result.clearedBalance.actualMoney.formatted()). Statement balance is \(result.statementBalance.actualMoney.formatted()). Difference is \(result.difference.actualMoney.formatted()). No data changed."
        case .failed(let message):
            return message
        }
    }

    var resultColor: Color {
        switch submissionState {
        case .reconciled:
            ActualistTheme.positive
        case .mismatch:
            ActualistTheme.warning
        case .failed:
            ActualistTheme.danger
        case .draft, .submitting:
            ActualistTheme.secondaryText
        }
    }

    func submit(
        budgetID: String,
        accountID: String,
        repository: (any AccountRepositoryProtocol)?
    ) async {
        guard let statementBalance = statementBalanceMinorUnits else {
            submissionState = .failed("Enter a valid statement balance.")
            return
        }

        guard let repository else {
            submissionState = .failed("Reconciliation is unavailable right now.")
            return
        }

        submissionState = .submitting
        do {
            let result = try await repository.reconcileAccountAndRefresh(
                budgetID: budgetID,
                accountID: accountID,
                statementBalance: statementBalance
            )
            submissionState = result.reconciled ? .reconciled(result) : .mismatch(result)
        } catch {
            submissionState = .failed(error.localizedDescription)
        }
    }

    private static func formattedInput(cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let absolute = abs(cents)
        return "\(sign)\(absolute / 100).\(String(format: "%02d", absolute % 100))"
    }

    private static func minorUnits(from text: String) -> Int? {
        let sanitized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")

        guard !sanitized.isEmpty else {
            return nil
        }

        let isNegative = sanitized.hasPrefix("-")
        let unsigned = isNegative ? String(sanitized.dropFirst()) : sanitized
        let pieces = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(pieces.count),
              let dollars = Int(pieces[0]),
              pieces[0].allSatisfy(\.isNumber) else {
            return nil
        }

        let cents: Int
        if pieces.count == 2 {
            guard pieces[1].count <= 2, pieces[1].allSatisfy(\.isNumber) else {
                return nil
            }
            cents = Int(pieces[1].padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        } else {
            cents = 0
        }

        let amount = dollars * 100 + cents
        return isNegative ? -amount : amount
    }
}

struct AccountReconciliationSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    @State private var viewModel: AccountReconciliationViewModel
    @FocusState private var isStatementBalanceFocused: Bool

    let account: ActualAccount
    let currentBalance: Int?

    init(
        account: ActualAccount,
        currentBalance: Int?
    ) {
        self.account = account
        self.currentBalance = currentBalance
        _viewModel = State(initialValue: AccountReconciliationViewModel(currentBalance: currentBalance))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ActualistTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        header
                        fields
                        resultBanner
                        submitButton
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .font(.body.weight(.semibold))
                    .controlSize(.small)
                }
            }
            .navigationTitle("Reconcile")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            await Task.yield()
            isStatementBalanceFocused = true
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(accountDisplayName)
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)

            Text(currentBalanceText)
                .font(ActualistTypography.workScreenAmount(for: density))
                .foregroundStyle(ActualistTheme.primaryText)

            Text("Working Balance")
                .font(ActualistTypography.body(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var accountDisplayName: String {
        guard !appState.settings.randomizedDisplayValuesEnabled else {
            return PrivacyDisplay.name(for: .account, seed: account.id)
        }

        return account.name
    }

    private var currentBalanceText: String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return (currentBalance ?? 0).actualMoney.formatted()
        }

        return PrivacyDisplay.money(
            currentBalance,
            seed: "reconcile-balance-\(account.id)",
            maximumDollars: 15_000
        )
    }

    private var fields: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "banknote.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .frame(width: density.iconSize)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Statement Balance")
                        .font(ActualistTypography.body(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)

                    TextField("0.00", text: $viewModel.statementBalanceText)
                        .focused($isStatementBalanceFocused)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.primaryText)
                        .tint(ActualistTheme.accent)
                }
            }
            .padding(.horizontal, density.rowHorizontalPadding)
            .padding(.vertical, density.editorRowVerticalPadding)

        }
        .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    @ViewBuilder
    private var resultBanner: some View {
        if let title = viewModel.resultTitle, let message = viewModel.resultMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(viewModel.resultColor)
                Text(message)
                    .font(ActualistTypography.body(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var submitButton: some View {
        Button {
            guard let budgetID = appState.settings.selectedBudgetID else {
                return
            }
            Task {
                await viewModel.submit(
                    budgetID: budgetID,
                    accountID: account.id,
                    repository: appState.makeAccountRepository()
                )
            }
        } label: {
            HStack(spacing: 8) {
                if viewModel.isSubmitting {
                    ProgressView()
                }
                Text(viewModel.submitTitle)
                    .font(ActualistTypography.control(for: density))
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 52)
        }
        .buttonStyle(.glassProminent)
        .tint(ActualistTheme.accent)
        .disabled(!viewModel.canSubmit || appState.settings.selectedBudgetID == nil)
    }
}

struct TransactionDateGroup: Hashable {
    let date: String
    let title: String
    let transactions: [ActualTransaction]
}

extension ActualTransaction {
    var rowID: String {
        id ?? "\(date)-\(account)-\(amount ?? 0)-\(importedPayee ?? "")"
    }
}

struct TransactionRow: View {
    @Environment(\.actualistDensity) private var density

    let transaction: ActualTransaction
    let payeeName: String
    let categoryNames: [String]
    let accountName: String?
    let isPrivacyModeEnabled: Bool
    let isNew: Bool
    let showsBottomSeparator: Bool

    init(
        transaction: ActualTransaction,
        payeeName: String,
        categoryNames: [String],
        accountName: String? = nil,
        isPrivacyModeEnabled: Bool = false,
        isNew: Bool = false,
        showsBottomSeparator: Bool = true
    ) {
        self.transaction = transaction
        self.payeeName = payeeName
        self.categoryNames = categoryNames
        self.accountName = accountName
        self.isPrivacyModeEnabled = isPrivacyModeEnabled
        self.isNew = isNew
        self.showsBottomSeparator = showsBottomSeparator
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(cleanedPayeeName)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)

                categoryBadges
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: 7) {
                Text(amountText)
                    .font(ActualistTypography.transactionAmount(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                if transaction.cleared?.boolValue == true {
                    Image(systemName: "c.circle.fill")
                        .font(.system(size: density.transactionClearedIconSize, weight: .bold))
                        .foregroundStyle(ActualistTheme.positive)
                }
            }
            .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(.horizontal, density.rowHorizontalPadding)
        .padding(.vertical, density.transactionRowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isNew ? ActualistTheme.elevatedSurface : Color.clear)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            if isNew {
                Rectangle()
                    .fill(ActualistTheme.accent.opacity(0.7))
                    .frame(width: 3)
            }
        }
        .overlay(alignment: .bottom) {
            if showsBottomSeparator {
                Rectangle()
                    .fill(ActualistTheme.separator)
                    .frame(height: 1)
            }
        }
    }

    private var categoryBadges: some View {
        HStack(spacing: 6) {
            ForEach(Array(displayCategoryNames.enumerated()), id: \.offset) { _, name in
                categoryBadge(name)
            }

            if let accountName {
                accountBadge(accountName)
            }
        }
    }

    private func categoryBadge(_ name: String) -> some View {
        let parts = name.actualistCategoryNameParts
        return HStack(spacing: 6) {
            if let emoji = parts.emoji {
                Text(verbatim: emoji)
                    .font(.actualistEmoji(size: 14))
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }

            Text(parts.name)
                .font(ActualistTypography.rowBadge(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
        }
            .padding(.horizontal, parts.emoji == nil ? 10 : 9)
            .padding(.vertical, 5)
            .background(ActualistTheme.control, in: Capsule())
    }

    private func accountBadge(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "building.columns.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ActualistTheme.secondaryText)
                .accessibilityHidden(true)

            Text(name)
                .font(ActualistTypography.rowBadge(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(ActualistTheme.elevatedSurface, in: Capsule())
    }

    private var cleanedPayeeName: String {
        payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var amountText: String {
        guard isPrivacyModeEnabled else {
            return (transaction.amount ?? 0).actualMoney.formatted()
        }

        return PrivacyDisplay.money(
            transaction.amount,
            seed: "transaction-amount-\(transaction.rowID)",
            maximumDollars: 275
        )
    }

    private var displayCategoryNames: [String] {
        guard categoryNames.count > 2 else {
            return categoryNames
        }
        return ["Split (\(categoryNames.count))"]
    }
}
