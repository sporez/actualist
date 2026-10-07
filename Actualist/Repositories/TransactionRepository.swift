import Foundation

enum TransactionQueryCapabilityError: LocalizedError, Equatable, Sendable {
    case unavailable

    var errorDescription: String? {
        "This transaction repository cannot provide exact query results."
    }
}

/// Local-first transaction reads and writes. Isolated to the main actor because
/// cached reads touch the store snapshot and write completions refresh UI.
@MainActor
protocol TransactionRepositoryProtocol: AnyObject {
    func cachedTransactions(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) -> LoadedAccountTransactions?
    func refreshTransactions(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) async throws
    func loadOlderTransactions(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) async throws
    func transactionPage(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions
    func cachedAccountTransactions(
        budgetID: String,
        accountID: String,
        statusFilter: TransactionStatusFilter
    ) -> LoadedAccountTransactions?
    func cachedSpendingTransactions(
        budgetID: String,
        statusFilter: TransactionStatusFilter
    ) -> LoadedAccountTransactions?
    func cachedCategoryTransactions(
        budgetID: String,
        categoryID: String,
        month: String
    ) -> LoadedAccountTransactions?
    func cachedUncategorizedTransactions(
        budgetID: String,
        month: String
    ) -> LoadedUncategorizedTransactions?
    func refreshAccountTransactions(
        budgetID: String,
        accountID: String,
        statusFilter: TransactionStatusFilter
    ) async throws
    func refreshSpendingTransactions(
        budgetID: String,
        statusFilter: TransactionStatusFilter
    ) async throws
    func refreshCategoryTransactions(
        budgetID: String,
        categoryID: String,
        month: String
    ) async throws
    func searchAccountTransactions(
        budgetID: String,
        accountID: String,
        query: String,
        limit: Int,
        offset: Int,
        statusFilter: TransactionStatusFilter
    ) async throws -> LoadedAccountTransactions
    func searchSpendingTransactions(
        budgetID: String,
        query: String,
        limit: Int,
        offset: Int,
        statusFilter: TransactionStatusFilter
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
    func existingImportedIDs(budgetID: String, accountID: String) async throws -> Set<String>
    func importWalletTransactions(
        _ candidates: [WalletTransactionCandidate],
        intoAccountID accountID: String,
        budgetID: String
    ) async throws -> WalletTransactionImportResult
    /// `transactionID` makes a retried create idempotent; `nil` mints a fresh id.
    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
        transactionID: String?,
        didCreate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult
    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult
    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        reconciliationAuthorization: ReconciledTransactionMutationAuthorization?,
        baseline: ActualTransaction?,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult
    func categorizeTransactionAndRefresh(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        reconciliationAuthorizations: [String: ReconciledTransactionMutationAuthorization],
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult
    func categorizeTransactionsAndRefresh(
        _ transactions: [ActualTransaction],
        categoryID: String,
        budgetID: String,
        reconciliationAuthorizations: [String: ReconciledTransactionMutationAuthorization],
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult
    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        didDelete: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult
    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        reconciliationAuthorization: ReconciledTransactionMutationAuthorization?,
        didDelete: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult
    func reconciledMutationReview(
        budgetID: String,
        transactionID: String
    ) async throws -> ReconciledTransactionMutationReview?
    func unlockReconciledTransactionAndRefresh(
        budgetID: String,
        accountID: String,
        transactionID: String
    ) async throws -> AccountReconciliationMutationResult
}

extension TransactionRepositoryProtocol {
    func cachedTransactions(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) -> LoadedAccountTransactions? {
        nil
    }

    func refreshTransactions(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) async throws {
        throw TransactionQueryCapabilityError.unavailable
    }

    func loadOlderTransactions(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) async throws {
        throw TransactionQueryCapabilityError.unavailable
    }

    func transactionPage(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        throw TransactionQueryCapabilityError.unavailable
    }

    func cachedAccountTransactions(budgetID: String, accountID: String) -> LoadedAccountTransactions? {
        cachedAccountTransactions(budgetID: budgetID, accountID: accountID, statusFilter: .all)
    }

    func cachedSpendingTransactions(budgetID: String) -> LoadedAccountTransactions? {
        cachedSpendingTransactions(budgetID: budgetID, statusFilter: .all)
    }

    func refreshAccountTransactions(budgetID: String, accountID: String) async throws {
        try await refreshAccountTransactions(budgetID: budgetID, accountID: accountID, statusFilter: .all)
    }

    func refreshSpendingTransactions(budgetID: String) async throws {
        try await refreshSpendingTransactions(budgetID: budgetID, statusFilter: .all)
    }

    func searchAccountTransactions(
        budgetID: String,
        accountID: String,
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        try await searchAccountTransactions(
            budgetID: budgetID, accountID: accountID, query: query, limit: limit, offset: offset,
            statusFilter: .all
        )
    }

    func searchSpendingTransactions(
        budgetID: String,
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        try await searchSpendingTransactions(
            budgetID: budgetID, query: query, limit: limit, offset: offset, statusFilter: .all
        )
    }

    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        reconciliationAuthorization: ReconciledTransactionMutationAuthorization?,
        baseline: ActualTransaction?,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await updateTransactionAndRefresh(
            transactionID,
            with: draft,
            budgetID: budgetID,
            originalAccountID: originalAccountID,
            originalMonth: originalMonth,
            didUpdate: didUpdate
        )
    }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        reconciliationAuthorization: ReconciledTransactionMutationAuthorization?,
        didDelete: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await deleteTransactionAndRefresh(
            transaction,
            budgetID: budgetID,
            didDelete: didDelete
        )
    }

    func reconciledMutationReview(
        budgetID: String,
        transactionID: String
    ) async throws -> ReconciledTransactionMutationReview? {
        nil
    }

    func unlockReconciledTransactionAndRefresh(
        budgetID: String,
        accountID: String,
        transactionID: String
    ) async throws -> AccountReconciliationMutationResult {
        throw LocalFirstError.unsupportedWrite
    }

    func existingImportedIDs(budgetID: String, accountID: String) async throws -> Set<String> {
        []
    }

    func importWalletTransactions(
        _ candidates: [WalletTransactionCandidate],
        intoAccountID accountID: String,
        budgetID: String
    ) async throws -> WalletTransactionImportResult {
        throw LocalFirstError.unsupportedWrite
    }

    func cachedUncategorizedTransactions(
        budgetID: String,
        month: String
    ) -> LoadedUncategorizedTransactions? {
        nil
    }

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
    /// True only for the synthetic To Budget option, so a real category that
    /// happens to be named "To Budget" is never mistaken for it.
    var isToBudget: Bool = false
}

struct LoadedAccountTransactions: Hashable, Sendable {
    let transactions: [ActualTransaction]
    let balance: Int?
    let accountNames: [String: String]
    let categoryNames: [String: String]
    let payeeNames: [String: String]
    let transferPayeeIDs: Set<String>
    let transferAccountIDsByPayeeID: [String: String]
    let offBudgetAccountIDs: Set<String>
    let reachedEnd: Bool
    let nextOffset: Int
    /// Present only when the repository can authoritatively classify the
    /// normalized query. Legacy snapshots intentionally leave this unavailable.
    let queryMetadata: TransactionQueryPageMetadata?

    var totalMatchCount: Int? { queryMetadata?.totalMatchCount }
    var querySignature: TransactionQuerySignature? { queryMetadata?.querySignature }
    var matchingTransactionIDs: Set<String>? { queryMetadata?.matchingTransactionIDs }
    var contributingTransactionIDs: Set<String>? { queryMetadata?.contributingTransactionIDs }
    var attachedContextTransactionIDs: Set<String>? { queryMetadata?.attachedContextTransactionIDs }

    init(
        transactions: [ActualTransaction],
        balance: Int?,
        accountNames: [String: String] = [:],
        categoryNames: [String: String],
        payeeNames: [String: String],
        transferPayeeIDs: Set<String>,
        transferAccountIDsByPayeeID: [String: String] = [:],
        offBudgetAccountIDs: Set<String> = [],
        reachedEnd: Bool,
        nextOffset: Int? = nil,
        queryMetadata: TransactionQueryPageMetadata? = nil
    ) {
        self.transactions = transactions
        self.balance = balance
        self.accountNames = accountNames
        self.categoryNames = categoryNames
        self.payeeNames = payeeNames
        self.transferPayeeIDs = transferPayeeIDs
        self.transferAccountIDsByPayeeID = transferAccountIDsByPayeeID
        self.offBudgetAccountIDs = offBudgetAccountIDs
        self.reachedEnd = reachedEnd
        self.nextOffset = nextOffset ?? transactions.count
        self.queryMetadata = queryMetadata
    }
}

extension LoadedAccountTransactions {
    func appendingPage(_ older: LoadedAccountTransactions) -> LoadedAccountTransactions {
        let mergedMetadata: TransactionQueryPageMetadata?
        switch (queryMetadata, older.queryMetadata) {
        case (nil, nil):
            mergedMetadata = nil
        case let (.some(current), .some(next)):
            guard current.querySignature == next.querySignature else { return self }
            let matchingIDs = current.matchingTransactionIDs.union(next.matchingTransactionIDs)
            mergedMetadata = TransactionQueryPageMetadata(
                totalMatchCount: next.totalMatchCount,
                querySignature: current.querySignature,
                matchingTransactionIDs: matchingIDs,
                contributingTransactionIDs: current.contributingTransactionIDs
                    .union(next.contributingTransactionIDs),
                attachedContextTransactionIDs: current.attachedContextTransactionIDs
                    .union(next.attachedContextTransactionIDs)
                    .subtracting(matchingIDs)
            )
        default:
            return self
        }
        let existingIDs = Set(transactions.map(Self.identity))
        return LoadedAccountTransactions(
            transactions: transactions + older.transactions.filter { !existingIDs.contains(Self.identity($0)) },
            balance: older.balance ?? balance,
            accountNames: older.accountNames.isEmpty ? accountNames : older.accountNames,
            categoryNames: older.categoryNames.isEmpty ? categoryNames : older.categoryNames,
            payeeNames: older.payeeNames.isEmpty ? payeeNames : older.payeeNames,
            transferPayeeIDs: older.transferPayeeIDs.isEmpty ? transferPayeeIDs : older.transferPayeeIDs,
            transferAccountIDsByPayeeID: older.transferAccountIDsByPayeeID.isEmpty
                ? transferAccountIDsByPayeeID : older.transferAccountIDsByPayeeID,
            offBudgetAccountIDs: older.offBudgetAccountIDs,
            reachedEnd: older.reachedEnd,
            nextOffset: older.nextOffset,
            queryMetadata: mergedMetadata
        )
    }

    private static func identity(_ transaction: ActualTransaction) -> String {
        let importedPayee = transaction.importedPayee ?? ""
        return transaction.id ?? "\(transaction.date)|\(transaction.account)|\(transaction.amount ?? 0)|\(importedPayee)"
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
            transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
            offBudgetAccountIDs: offBudgetAccountIDs,
            reachedEnd: reachedEnd,
            nextOffset: nextOffset,
            queryMetadata: nil
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
    let transferAccountIDsByPayeeID: [String: String]
    let offBudgetAccountIDs: Set<String>
    let categoryGroups: [TransactionEditorCategoryGroup]

    init(
        transactions: [ActualTransaction],
        accountNames: [String: String],
        categoryNames: [String: String],
        payeeNames: [String: String],
        transferPayeeIDs: Set<String>,
        transferAccountIDsByPayeeID: [String: String] = [:],
        offBudgetAccountIDs: Set<String> = [],
        categoryGroups: [TransactionEditorCategoryGroup]
    ) {
        self.transactions = transactions
        self.accountNames = accountNames
        self.categoryNames = categoryNames
        self.payeeNames = payeeNames
        self.transferPayeeIDs = transferPayeeIDs
        self.transferAccountIDsByPayeeID = transferAccountIDsByPayeeID
        self.offBudgetAccountIDs = offBudgetAccountIDs
        self.categoryGroups = categoryGroups
    }
}
