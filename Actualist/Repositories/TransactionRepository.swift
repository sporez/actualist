import Foundation

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
    func transactionDrilldown(
        budgetID: String,
        request: TransactionDrilldownRequest
    ) async throws -> TransactionDrilldownResult
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
    func loadOlderTransactions(
        budgetID: String,
        accountID: String,
        statusFilter: TransactionStatusFilter
    ) async throws
    func loadOlderSpendingTransactions(
        budgetID: String,
        statusFilter: TransactionStatusFilter
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
    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
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
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult
    func categorizeTransactionAndRefresh(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult
    func categorizeTransactionsAndRefresh(
        _ transactions: [ActualTransaction],
        categoryID: String,
        budgetID: String,
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
        guard query.text == nil, !query.hasStructuredConditions else { return nil }
        switch scope {
        case .account(let accountID):
            return cachedAccountTransactions(
                budgetID: budgetID,
                accountID: accountID,
                statusFilter: query.status
            )
        case .spending:
            return cachedSpendingTransactions(budgetID: budgetID, statusFilter: query.status)
        }
    }

    func refreshTransactions(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) async throws {
        guard query.text == nil, !query.hasStructuredConditions else {
            throw LocalFirstError.unsupportedWrite
        }
        switch scope {
        case .account(let accountID):
            try await refreshAccountTransactions(
                budgetID: budgetID,
                accountID: accountID,
                statusFilter: query.status
            )
        case .spending:
            try await refreshSpendingTransactions(budgetID: budgetID, statusFilter: query.status)
        }
    }

    func loadOlderTransactions(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) async throws {
        guard query.text == nil, !query.hasStructuredConditions else {
            throw LocalFirstError.unsupportedWrite
        }
        switch scope {
        case .account(let accountID):
            try await loadOlderTransactions(
                budgetID: budgetID,
                accountID: accountID,
                statusFilter: query.status
            )
        case .spending:
            try await loadOlderSpendingTransactions(budgetID: budgetID, statusFilter: query.status)
        }
    }

    func transactionPage(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        guard !query.hasStructuredConditions, let text = query.text else {
            throw LocalFirstError.unsupportedWrite
        }
        let loaded: LoadedAccountTransactions
        switch scope {
        case .account(let accountID):
            loaded = try await searchAccountTransactions(
                budgetID: budgetID,
                accountID: accountID,
                query: text,
                limit: limit,
                offset: offset,
                statusFilter: query.status
            )
        case .spending:
            loaded = try await searchSpendingTransactions(
                budgetID: budgetID,
                query: text,
                limit: limit,
                offset: offset,
                statusFilter: query.status
            )
        }
        return loaded.replacingQueryMetadata(signature: query.signature)
    }

    func transactionDrilldown(
        budgetID: String,
        request: TransactionDrilldownRequest
    ) async throws -> TransactionDrilldownResult {
        throw LocalFirstError.unsupportedWrite
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

    func loadOlderTransactions(budgetID: String, accountID: String) async throws {
        try await loadOlderTransactions(budgetID: budgetID, accountID: accountID, statusFilter: .all)
    }

    func loadOlderSpendingTransactions(budgetID: String) async throws {
        try await loadOlderSpendingTransactions(budgetID: budgetID, statusFilter: .all)
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
    let totalMatchCount: Int
    let querySignature: TransactionQuerySignature
    let matchingTransactionIDs: Set<String>
    let contributingTransactionIDs: Set<String>
    let attachedContextTransactionIDs: Set<String>

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
        totalMatchCount: Int? = nil,
        querySignature: TransactionQuerySignature = TransactionFeedQuery.all.signature,
        matchingTransactionIDs: Set<String>? = nil,
        contributingTransactionIDs: Set<String>? = nil,
        attachedContextTransactionIDs: Set<String> = []
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
        self.totalMatchCount = totalMatchCount ?? transactions.count
        self.querySignature = querySignature
        let physicalTransactions = transactions.flatMap { [$0] + $0.subtransactions }
        let physicalIDs = Set(physicalTransactions.compactMap(\.id))
        self.matchingTransactionIDs = matchingTransactionIDs ?? physicalIDs
        self.contributingTransactionIDs = contributingTransactionIDs ?? Set(
            physicalTransactions.filter { !$0.isParent }.compactMap(\.id)
        )
        self.attachedContextTransactionIDs = attachedContextTransactionIDs
    }
}

extension LoadedAccountTransactions {
    func appendingPage(_ older: LoadedAccountTransactions) -> LoadedAccountTransactions {
        guard querySignature == older.querySignature else { return self }
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
            totalMatchCount: older.totalMatchCount,
            querySignature: querySignature,
            matchingTransactionIDs: matchingTransactionIDs.union(older.matchingTransactionIDs),
            contributingTransactionIDs: contributingTransactionIDs.union(older.contributingTransactionIDs),
            attachedContextTransactionIDs: attachedContextTransactionIDs.union(older.attachedContextTransactionIDs)
        )
    }

    func replacingQueryMetadata(signature: TransactionQuerySignature) -> LoadedAccountTransactions {
        LoadedAccountTransactions(
            transactions: transactions,
            balance: balance,
            accountNames: accountNames,
            categoryNames: categoryNames,
            payeeNames: payeeNames,
            transferPayeeIDs: transferPayeeIDs,
            transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
            offBudgetAccountIDs: offBudgetAccountIDs,
            reachedEnd: reachedEnd,
            nextOffset: nextOffset,
            totalMatchCount: totalMatchCount,
            querySignature: signature,
            matchingTransactionIDs: matchingTransactionIDs,
            contributingTransactionIDs: contributingTransactionIDs,
            attachedContextTransactionIDs: attachedContextTransactionIDs
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
            totalMatchCount: totalMatchCount,
            querySignature: querySignature,
            matchingTransactionIDs: matchingTransactionIDs,
            contributingTransactionIDs: contributingTransactionIDs,
            attachedContextTransactionIDs: attachedContextTransactionIDs
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
