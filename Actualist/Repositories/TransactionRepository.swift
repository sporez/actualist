import Foundation

protocol TransactionRepositoryProtocol: Sendable {
    func editorOptions(budgetID: String) async throws -> TransactionEditorOptions
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
    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        didDelete: @escaping () async -> Void
    ) async throws -> TransactionMutationResult
}

struct TransactionRepository: Sendable {
    let client: ActualAPIClient

    func editorOptions(budgetID: String) async throws -> TransactionEditorOptions {
        async let loadedAccounts = client.accounts(budgetID: budgetID)
        async let loadedCategories = client.categories(budgetID: budgetID)
        async let loadedPayees = client.payees(budgetID: budgetID)

        let fetchedAccounts = try await loadedAccounts
        let fetchedCategories = try await loadedCategories

        return TransactionEditorOptions(
            accounts: fetchedAccounts.filter { !$0.closed },
            categories: fetchedCategories.filter { !($0.hidden ?? false) && !($0.isIncome ?? false) },
            payees: try await loadedPayees
        )
    }

    func accountTransactions(
        budgetID: String,
        accountID: String
    ) async throws -> LoadedAccountTransactions {
        async let loadedTransactions = client.transactions(budgetID: budgetID, accountID: accountID)
        async let loadedBalance = client.balance(budgetID: budgetID, accountID: accountID)
        async let loadedCategories = client.categories(budgetID: budgetID)
        async let loadedPayees = client.payees(budgetID: budgetID)

        let categoryNames = Dictionary(uniqueKeysWithValues: (try await loadedCategories).compactMap { category in
            category.id.map { ($0, category.name) }
        })
        let payeeNames = Dictionary(uniqueKeysWithValues: (try await loadedPayees).compactMap { payee in
            payee.id.map { ($0, payee.name) }
        })

        return LoadedAccountTransactions(
            transactions: try await loadedTransactions,
            balance: try? await loadedBalance,
            categoryNames: categoryNames,
            payeeNames: payeeNames
        )
    }

    func previewRules(
        for draft: TransactionDraft,
        budgetID: String
    ) async throws -> TransactionRulePreview {
        try await client.runTransactionRules(budgetID: budgetID, draft: draft)
    }

    func createTransaction(
        _ draft: TransactionDraft,
        budgetID: String
    ) async throws -> TransactionMutationResult {
        let api = ActualBudgetAPI(budgetID: budgetID, client: client)
        return try await api.createTransaction(draft)
    }

    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
        didCreate: @escaping () async -> Void = {}
    ) async throws -> TransactionMutationResult {
        let result = try await createTransaction(draft, budgetID: budgetID)
        await didCreate()
        try await refreshAffectedResources(result.changed, budgetID: budgetID)
        return result
    }

    func updateTransaction(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String
    ) async throws -> TransactionMutationResult {
        _ = try await client.updateTransaction(
            budgetID: budgetID,
            transactionID: transactionID,
            draft: draft
        )

        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: Self.uniquePreservingOrder([originalAccountID, draft.accountID]),
                months: Self.uniquePreservingOrder([originalMonth, draft.month.rawValue]),
                transactions: [transactionID]
            )
        )
    }

    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        didUpdate: @escaping () async -> Void = {}
    ) async throws -> TransactionMutationResult {
        let result = try await updateTransaction(
            transactionID,
            with: draft,
            budgetID: budgetID,
            originalAccountID: originalAccountID,
            originalMonth: originalMonth
        )
        await didUpdate()
        try await refreshAffectedResources(result.changed, budgetID: budgetID)
        return result
    }

    func deleteTransaction(
        _ transaction: ActualTransaction,
        budgetID: String
    ) async throws -> TransactionMutationResult {
        _ = try await client.deleteTransaction(budgetID: budgetID, transaction: transaction)

        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: [transaction.account],
                months: transaction.date.actualYearMonth.map { [$0] } ?? [],
                transactions: transaction.id.map { [$0] } ?? []
            )
        )
    }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        didDelete: @escaping () async -> Void = {}
    ) async throws -> TransactionMutationResult {
        let result = try await deleteTransaction(transaction, budgetID: budgetID)
        await didDelete()
        try await refreshAffectedResources(result.changed, budgetID: budgetID)
        return result
    }

    func refreshAffectedResources(
        _ changed: ChangedResources,
        budgetID: String
    ) async throws {
        for accountID in changed.accounts {
            _ = try await client.balance(budgetID: budgetID, accountID: accountID)
            _ = try await client.transactions(budgetID: budgetID, accountID: accountID)
        }

        for month in changed.months {
            _ = try await client.budgetMonth(budgetID: budgetID, month: month)
        }
    }

    private static func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

struct TransactionEditorOptions: Hashable, Sendable {
    let accounts: [ActualAccount]
    let categories: [ActualCategory]
    let payees: [ActualPayee]
}

struct LoadedAccountTransactions: Hashable, Sendable {
    let transactions: [ActualTransaction]
    let balance: Int?
    let categoryNames: [String: String]
    let payeeNames: [String: String]
}

extension TransactionRepository: TransactionRepositoryProtocol {}
