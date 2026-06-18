import SwiftUI

struct AccountTransactionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    let account: ActualAccount

    @State private var groups: [TransactionDateGroup] = []
    @State private var isLoading = false
    @State private var isLoadingOlder = false
    @State private var errorMessage: String?
    @State private var transactionEditorPresentation: TransactionEditorPresentation?
    @State private var deletePresentation: TransactionDeletePresentation?
    @State private var deletingTransactionID: String?
    @State private var deleteIntentHaptic = 0
    @State private var deleteSuccessHaptic = 0

    private var budgetID: String? {
        appState.settings.selectedBudgetID
    }

    /// Reactive composed snapshot from the shared store (cached instantly, revalidated in `load`).
    private var loaded: LoadedAccountTransactions? {
        guard let budgetID else {
            return nil
        }
        return appState.dataStore.cachedAccountTransactions(budgetID: budgetID, accountID: account.id)
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

    private var payeeNames: [String: String] {
        loaded?.payeeNames ?? [:]
    }

    private var reachedEnd: Bool {
        loaded?.reachedEnd ?? false
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                addTransactionButton
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            transactionList

            olderTransactionsFooter

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
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .actualistToolbarGlassButton()

                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .actualistToolbarGlassButton()
            }
        }
        .task {
            groups = TransactionGrouping.grouped(transactions)
            await load()
        }
        .refreshable { await load() }
        .onChange(of: transactions) { _, updated in
            groups = TransactionGrouping.grouped(updated)
        }
        .sensoryFeedback(.selection, trigger: deleteIntentHaptic)
        .sensoryFeedback(.success, trigger: deleteSuccessHaptic)
        .sheet(item: $transactionEditorPresentation) { presentation in
            TransactionEditorView(
                prefilledAccount: account,
                editingTransaction: presentation.transaction,
                prefilledPayeeName: presentation.payeeName,
                prefilledCategoryName: presentation.categoryName
            ) {
                Task { await load() }
            }
                .environment(appState)
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
                Text("Delete \(deletePresentation.payeeName)? Actualist will confirm the server update before refreshing this account.")
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text((balance ?? 0).actualMoney.formatted())
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

    private var addTransactionButton: some View {
        Button {
            transactionEditorPresentation = .create
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.body.weight(.bold))
                Text("Add Transaction")
                    .font(ActualistTypography.control(for: density))
            }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .tint(ActualistTheme.accent)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var transactionList: some View {
        ForEach(groups, id: \.date) { group in
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

            ForEach(group.transactions, id: \.rowID) { transaction in
                transactionButton(for: transaction)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(ActualistTheme.surface)
            }
        }
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

    private func transactionButton(for transaction: ActualTransaction) -> some View {
        Button {
            transactionEditorPresentation = .edit(
                transaction,
                payeeName: payeeName(for: transaction),
                categoryName: categoryName(for: transaction)
            )
        } label: {
            TransactionRow(
                transaction: transaction,
                payeeName: payeeName(for: transaction),
                categoryName: categoryName(for: transaction)
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
            .disabled(transaction.id == nil || deletingTransactionID != nil)
        }
    }

    private func requestDelete(_ transaction: ActualTransaction) {
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
        guard let budgetID else {
            return
        }

        deletingTransactionID = transaction.rowID
        isLoading = true
        errorMessage = nil

        do {
            // The store invalidates and refetches the affected account + month, so the reactive
            // snapshot (and the Budget tab) refresh without a second round trip here.
            _ = try await appState.dataStore.deleteTransactionAndRefresh(
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

    private func payeeName(for transaction: ActualTransaction) -> String {
        if let payeeName = transaction.payeeName, !payeeName.isEmpty {
            return payeeName
        }
        if let payee = transaction.payee, let name = payeeNames[payee] {
            return name
        }
        if let importedPayee = transaction.importedPayee, !importedPayee.isEmpty {
            return importedPayee
        }
        return "Unknown Payee"
    }

    private func categoryName(for transaction: ActualTransaction) -> String {
        guard let category = transaction.category else {
            return "Uncategorized"
        }
        return categoryNames[category] ?? "Uncategorized"
    }

    private func load() async {
        guard let budgetID else {
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            try await appState.dataStore.refreshAccountTransactions(budgetID: budgetID, accountID: account.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadOlder() async {
        guard let budgetID, loaded != nil, !reachedEnd, !isLoading, !isLoadingOlder else {
            return
        }

        isLoadingOlder = true
        errorMessage = nil
        do {
            try await appState.dataStore.loadOlderTransactions(budgetID: budgetID, accountID: account.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingOlder = false
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
    let categoryName: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(cleanedPayeeName)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)

                categoryBadge
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: 7) {
                Text((transaction.amount ?? 0).actualMoney.formatted())
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
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ActualistTheme.separator)
                .frame(height: 1)
        }
    }

    private var categoryBadge: some View {
        HStack(spacing: 6) {
            if let emoji = categoryParts.emoji {
                Text(verbatim: emoji)
                    .font(.actualistEmoji(size: 14))
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }

            Text(categoryParts.name)
                .font(ActualistTypography.rowBadge(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
        }
            .padding(.horizontal, categoryParts.emoji == nil ? 10 : 9)
            .padding(.vertical, 5)
            .background(ActualistTheme.control, in: Capsule())
    }

    private var cleanedPayeeName: String {
        payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var categoryParts: CategoryNameParts {
        categoryName.actualistCategoryNameParts
    }
}
