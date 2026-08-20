import Foundation

struct AccountTransactionRowPresentation: Identifiable, Hashable {
    let transaction: ActualTransaction
    let payeeName: String
    let categoryNames: [String]
    let accountName: String?
    let isNew: Bool

    var id: String { transaction.rowID }
}

struct AccountTransactionDateGroupPresentation: Identifiable, Hashable {
    let date: String
    let title: String
    let rows: [AccountTransactionRowPresentation]

    var id: String { date }
}

struct AccountTransactionCategorySummaryPresentation: Hashable {
    let budgetedText: String
    let spentText: String
    let remainingText: String
    let remainingTone: AccountTransactionBalanceTone
}

struct AccountTransactionsDisplayState: Hashable {
    let title: String
    let balanceText: String
    let groups: [AccountTransactionDateGroupPresentation]
    let categorySummary: AccountTransactionCategorySummaryPresentation?
    let hasLoadedSnapshot: Bool
    let reachedEnd: Bool

    var transactionCount: Int {
        groups.reduce(into: 0) { $0 += $1.rows.count }
    }
}

enum AccountTransactionBalanceTone: Equatable {
    case negative
    case zero
    case positive
}

struct AccountTransactionFeedProjection {
    let scope: TransactionFeedScope
    let loaded: LoadedAccountTransactions?
    let searchLoaded: LoadedAccountTransactions?
    let query: String
    let pendingNewTransactionIDs: Set<String>
    let privacyModeEnabled: Bool

    var displayState: AccountTransactionsDisplayState {
        let groups = TransactionGrouping.grouped(displayedTransactions).map { group in
            AccountTransactionDateGroupPresentation(
                date: group.date,
                title: group.title,
                rows: group.transactions.map(rowPresentation)
            )
        }
        return AccountTransactionsDisplayState(
            title: scopeTitle,
            balanceText: balanceText,
            groups: groups,
            categorySummary: categorySummary,
            hasLoadedSnapshot: loaded != nil,
            reachedEnd: loaded?.reachedEnd ?? false
        )
    }

    func editorPresentation(for transaction: ActualTransaction) -> TransactionEditorPresentation {
        .edit(
            transaction,
            payeeName: payeeName(for: transaction),
            categoryName: categoryNames(for: transaction).first ?? "Uncategorized"
        )
    }

    func deletePresentation(for transaction: ActualTransaction) -> TransactionDeletePresentation {
        TransactionDeletePresentation(
            transaction: transaction,
            payeeName: payeeName(for: transaction)
        )
    }

    private var activeLoaded: LoadedAccountTransactions? {
        searchLoaded ?? loaded
    }

    private var displayedTransactions: [ActualTransaction] {
        guard !query.isEmpty else { return loaded?.transactions ?? [] }
        if let searchLoaded { return searchLoaded.transactions }
        guard let loaded else { return [] }
        return loaded.transactions.filter { transaction in
            matches(payeeName(for: transaction))
                || categoryNames(for: transaction).contains(where: matches)
                || matches(accountName(for: transaction))
                || transaction.subtransactions.contains { matches($0.notes) }
                || matches(transaction.importedPayee)
                || matches(transaction.notes)
        }
    }

    private func rowPresentation(_ transaction: ActualTransaction) -> AccountTransactionRowPresentation {
        AccountTransactionRowPresentation(
            transaction: transaction,
            payeeName: privacyModeEnabled
                ? PrivacyDisplay.name(for: .payee, seed: "payee-\(transaction.rowID)")
                : payeeName(for: transaction),
            categoryNames: privacyModeEnabled
                ? privateCategoryNames(for: transaction)
                : categoryNames(for: transaction),
            accountName: privacyModeEnabled && scope.showsAccountNames
                ? PrivacyDisplay.name(for: .account, seed: transaction.account)
                : accountName(for: transaction),
            isNew: transaction.id.map { pendingNewTransactionIDs.contains($0) } ?? false
        )
    }

    private func payeeName(for transaction: ActualTransaction) -> String {
        TransactionPayeePresentation.name(
            for: transaction,
            payeeNames: activeLoaded?.payeeNames ?? [:]
        )
    }

    private func categoryNames(for transaction: ActualTransaction) -> [String] {
        TransactionCategoryPresentation.names(
            for: transaction,
            categoryNames: activeLoaded?.categoryNames ?? [:],
            transferPayeeIDs: activeLoaded?.transferPayeeIDs ?? [],
            transferAccountIDsByPayeeID: activeLoaded?.transferAccountIDsByPayeeID ?? [:],
            offBudgetAccountIDs: activeLoaded?.offBudgetAccountIDs ?? []
        )
    }

    private func accountName(for transaction: ActualTransaction) -> String? {
        guard scope.showsAccountNames else { return nil }
        let name = activeLoaded?.accountNames[transaction.account]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : "Unknown Account"
    }

    private func matches(_ value: String?) -> Bool {
        guard let value, !query.isEmpty else { return false }
        return value.localizedCaseInsensitiveContains(query)
    }

    private var scopeTitle: String {
        guard privacyModeEnabled else { return scope.title }
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
        guard privacyModeEnabled else { return (loaded?.balance ?? 0).actualMoney.formatted() }
        let seed = scope.account.map { "account-header-\($0.id)" } ?? "spending-header"
        return PrivacyDisplay.money(loaded?.balance, seed: seed, maximumDollars: 15_000)
    }

    private var categorySummary: AccountTransactionCategorySummaryPresentation? {
        guard let details = scope.categoryDetails else { return nil }
        return AccountTransactionCategorySummaryPresentation(
            budgetedText: summaryAmountText(details.budgetedAmount, label: "Budgeted"),
            spentText: summaryAmountText(details.spentAmount, label: "Spent"),
            remainingText: summaryAmountText(details.remainingAmount, label: "Remaining"),
            remainingTone: balanceTone(details.remainingAmount)
        )
    }

    private func summaryAmountText(_ amount: Int, label: String) -> String {
        guard privacyModeEnabled else { return amount.actualMoney.formatted() }
        return PrivacyDisplay.money(
            amount,
            seed: "category-summary-\(scope.categoryDetails?.id ?? label)-\(label)",
            maximumDollars: 2_500
        )
    }

    private func balanceTone(_ amount: Int) -> AccountTransactionBalanceTone {
        if amount < 0 { return .negative }
        if amount == 0 { return .zero }
        return .positive
    }

    private func privateCategoryNames(for transaction: ActualTransaction) -> [String] {
        if !transaction.subtransactions.isEmpty {
            return transaction.subtransactions.map { child in
                PrivacyDisplay.name(for: .category, seed: "category-\(child.rowID)")
            }
        }
        return [PrivacyDisplay.name(for: .category, seed: "category-\(transaction.rowID)")]
    }
}
