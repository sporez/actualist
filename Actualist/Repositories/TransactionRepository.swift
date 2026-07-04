import Foundation

protocol TransactionRepositoryProtocol: Sendable {
    func cachedAccountTransactions(budgetID: String, accountID: String) -> LoadedAccountTransactions?
    func cachedSpendingTransactions(budgetID: String) -> LoadedAccountTransactions?
    func refreshAccountTransactions(budgetID: String, accountID: String) async throws
    func refreshSpendingTransactions(budgetID: String) async throws
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

struct LoadedUncategorizedTransactions: Hashable, Sendable {
    let transactions: [ActualTransaction]
    let accountNames: [String: String]
    let categoryNames: [String: String]
    let payeeNames: [String: String]
    let transferPayeeIDs: Set<String>
    let categoryGroups: [TransactionEditorCategoryGroup]
}
