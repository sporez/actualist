import Foundation

protocol TransactionRepositoryProtocol: Sendable {
    func cachedAccountTransactions(budgetID: String, accountID: String) -> LoadedAccountTransactions?
    func cachedSpendingTransactions(budgetID: String) -> LoadedAccountTransactions?
    func cachedCategoryTransactions(
        budgetID: String,
        categoryID: String,
        month: String
    ) -> LoadedAccountTransactions?
    func refreshAccountTransactions(budgetID: String, accountID: String) async throws
    func refreshSpendingTransactions(budgetID: String) async throws
    func refreshCategoryTransactions(
        budgetID: String,
        categoryID: String,
        month: String
    ) async throws
    func loadOlderTransactions(budgetID: String, accountID: String) async throws
    func loadOlderSpendingTransactions(budgetID: String) async throws
    func searchAccountTransactions(
        budgetID: String,
        accountID: String,
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions
    func searchSpendingTransactions(
        budgetID: String,
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions
    func editorOptions(budgetID: String, month: String) async throws -> TransactionEditorOptions
    func uncategorizedTransactions(
        budgetID: String,
        month: String
    ) async throws -> LoadedUncategorizedTransactions
    func previewRules(
        for draft: TransactionDraft,
        budgetID: String
    ) async throws -> TransactionRulePreview
    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
        didCreate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult
    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult
    func categorizeTransactionAndRefresh(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult
    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        didDelete: @escaping () async -> Void
    ) async throws -> TransactionMutationResult
}

extension TransactionRepositoryProtocol {
    func cachedCategoryTransactions(
        budgetID: String,
        categoryID: String,
        month: String
    ) -> LoadedAccountTransactions? {
        cachedSpendingTransactions(budgetID: budgetID)?.filtering(categoryID: categoryID, month: month)
    }

    func refreshCategoryTransactions(
        budgetID: String,
        categoryID: String,
        month: String
    ) async throws {
        try await refreshSpendingTransactions(budgetID: budgetID)
    }
}

struct TransactionEditorOptions: Hashable, Sendable {
    let accounts: [ActualAccount]
    let categories: [ActualCategory]
    let categoryGroups: [TransactionEditorCategoryGroup]
    let payees: [ActualPayee]
}

struct TransactionEditorCategoryGroup: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let options: [TransactionEditorCategoryOption]
}

struct TransactionEditorCategoryOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let amount: Int?
    let valueText: String?
}

struct LoadedAccountTransactions: Hashable, Sendable {
    let transactions: [ActualTransaction]
    let balance: Int?
    let accountNames: [String: String]
    let categoryNames: [String: String]
    let payeeNames: [String: String]
    let transferPayeeIDs: Set<String>
    let reachedEnd: Bool

    init(
        transactions: [ActualTransaction],
        balance: Int?,
        accountNames: [String: String] = [:],
        categoryNames: [String: String],
        payeeNames: [String: String],
        transferPayeeIDs: Set<String>,
        reachedEnd: Bool
    ) {
        self.transactions = transactions
        self.balance = balance
        self.accountNames = accountNames
        self.categoryNames = categoryNames
        self.payeeNames = payeeNames
        self.transferPayeeIDs = transferPayeeIDs
        self.reachedEnd = reachedEnd
    }
}

extension LoadedAccountTransactions {
    func filtering(categoryID: String, month: String) -> LoadedAccountTransactions {
        LoadedAccountTransactions(
            transactions: transactions.filter { transaction in
                transaction.belongs(toCategory: categoryID, month: month)
            },
            balance: nil,
            accountNames: accountNames,
            categoryNames: categoryNames,
            payeeNames: payeeNames,
            transferPayeeIDs: transferPayeeIDs,
            reachedEnd: reachedEnd
        )
    }
}

extension ActualTransaction {
    func belongs(toCategory categoryID: String, month: String) -> Bool {
        guard date.hasPrefix("\(month)-") else {
            return false
        }
        return category == categoryID || subtransactions.contains { $0.category == categoryID }
    }
}

struct LoadedUncategorizedTransactions: Hashable, Sendable {
    let transactions: [ActualTransaction]
    let accountNames: [String: String]
    let categoryNames: [String: String]
    let payeeNames: [String: String]
    let transferPayeeIDs: Set<String>
    let categoryGroups: [TransactionEditorCategoryGroup]
}
