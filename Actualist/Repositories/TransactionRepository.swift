import Foundation

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

    func createTransaction(
        _ draft: TransactionDraft,
        budgetID: String
    ) async throws -> TransactionMutationResult {
        let api = ActualBudgetAPI(budgetID: budgetID, client: client)
        return try await api.createTransaction(draft)
    }

    func refreshAffectedResources(
        _ changed: ChangedResources,
        budgetID: String
    ) async throws {
        for accountID in changed.accounts {
            _ = try? await client.balance(budgetID: budgetID, accountID: accountID)
            _ = try await client.transactions(budgetID: budgetID, accountID: accountID)
        }

        for month in changed.months {
            _ = try await client.budgetMonth(budgetID: budgetID, month: month)
        }
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
