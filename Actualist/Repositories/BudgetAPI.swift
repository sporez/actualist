import Foundation

protocol BudgetAPI: Sendable {
    func getBudgetMonth(_ month: YearMonth) async throws -> BudgetMonth
    func getAccounts() async throws -> [BudgetAccount]
    func getTransactions(accountID: String) async throws -> [ActualTransaction]
    func createTransaction(_ draft: TransactionDraft) async throws -> TransactionMutationResult
}

struct ActualBudgetAPI: BudgetAPI {
    let budgetID: String
    let client: ActualAPIClient

    func getBudgetMonth(_ month: YearMonth) async throws -> BudgetMonth {
        try await client.budgetMonth(budgetID: budgetID, month: month.rawValue)
    }

    func getAccounts() async throws -> [BudgetAccount] {
        try await client.accounts(budgetID: budgetID)
    }

    func getTransactions(accountID: String) async throws -> [ActualTransaction] {
        try await client.transactions(budgetID: budgetID, accountID: accountID)
    }

    func createTransaction(_ draft: TransactionDraft) async throws -> TransactionMutationResult {
        _ = try await client.createTransaction(budgetID: budgetID, draft: draft)

        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: [draft.accountID],
                months: [draft.month.rawValue],
                transactions: []
            )
        )
    }
}

typealias BudgetAccount = ActualAccount

struct YearMonth: Hashable, Sendable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(date: Date) {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        self.rawValue = String(format: "%04d-%02d", components.year ?? 1970, components.month ?? 1)
    }
}

struct TransactionDraft: Hashable, Sendable {
    let accountID: String
    let date: Date
    let amountMinorUnits: Int
    let payeeID: String?
    let payeeName: String
    let categoryID: String?
    let notes: String?
    let cleared: Bool

    var month: YearMonth {
        YearMonth(date: date)
    }
}

struct TransactionMutationResult: Hashable, Sendable {
    let ok: Bool
    let changed: ChangedResources
}

struct ChangedResources: Hashable, Sendable {
    let accounts: [String]
    let months: [String]
    let transactions: [String]
}

struct TransactionRulePreview: Hashable, Sendable {
    let categoryID: String?
    let notes: String?
}
