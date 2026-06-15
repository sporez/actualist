import SwiftUI

struct AccountTransactionsView: View {
    @Environment(AppState.self) private var appState
    let account: ActualAccount

    @State private var transactions: [ActualTransaction] = []
    @State private var categoryNames: [String: String] = [:]
    @State private var payeeNames: [String: String] = [:]
    @State private var balance: Int?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var transactionEditorPresentation: TransactionEditorPresentation?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header

                Button {
                    transactionEditorPresentation = .create
                } label: {
                    Label("Add Transaction", systemImage: "plus.circle.fill")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.glassProminent)
                .tint(ActualistTheme.accent)
                .padding(.horizontal, 16)

                transactionList

                if isLoading {
                    ProgressView("Loading transactions")
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(ActualistTheme.danger)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 28)
        }
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
        .task { await load() }
        .refreshable { await load() }
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
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text((balance ?? 0).actualMoney.formatted())
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(ActualistTheme.primaryText)
            Text("Working Balance")
                .font(.headline)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.horizontal, 16)
    }

    private var transactionList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(groupedTransactions, id: \.date) { group in
                Text(group.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .padding(.top, 22)
                    .padding(.bottom, 12)
                    .padding(.horizontal, 16)

                VStack(spacing: 0) {
                    ForEach(group.transactions, id: \.rowID) { transaction in
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
                    }
                }
                .frame(maxWidth: .infinity)
                .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 0, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var groupedTransactions: [TransactionDateGroup] {
        let groups = Dictionary(grouping: transactions) { $0.date }
        return groups.keys.sorted(by: >).map { date in
            TransactionDateGroup(date: date, title: formattedDate(date), transactions: groups[date] ?? [])
        }
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

    private func formattedDate(_ value: String) -> String {
        let input = DateFormatter()
        input.dateFormat = "yyyy-MM-dd"
        guard let date = input.date(from: value) else {
            return value
        }

        let output = DateFormatter()
        output.dateStyle = .long
        return output.string(from: date)
    }

    private func load() async {
        guard let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeTransactionRepository() else {
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await repository.accountTransactions(budgetID: budgetID, accountID: account.id)
            transactions = loaded.transactions
            balance = loaded.balance
            categoryNames = loaded.categoryNames
            payeeNames = loaded.payeeNames
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
    let transaction: ActualTransaction
    let payeeName: String
    let categoryName: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text(cleanedPayeeName)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)

                categoryBadge
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                Text((transaction.amount ?? 0).actualMoney.formatted())
                    .font(.headline.weight(.bold))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                if transaction.cleared?.boolValue == true {
                    Image(systemName: "c.circle.fill")
                        .foregroundStyle(ActualistTheme.positive)
                }
            }
            .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
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
                    .font(.actualistEmoji(size: 16))
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }

            Text(categoryParts.name)
                .font(.callout.weight(.medium))
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
        }
            .padding(.horizontal, categoryParts.emoji == nil ? 12 : 10)
            .padding(.vertical, 6)
            .background(ActualistTheme.control, in: Capsule())
    }

    private var cleanedPayeeName: String {
        payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var categoryParts: CategoryNameParts {
        categoryName.actualistCategoryNameParts
    }
}
