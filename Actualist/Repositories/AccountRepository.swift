import Foundation

protocol AccountRepositoryProtocol: Sendable {
    @MainActor
    func accountDisplays(budgetID: String) -> [AccountDisplay]

    @MainActor
    func refreshAccountsWithBalances(budgetID: String) async throws

    // MARK: - Account mutations / server operations

    @MainActor
    func createAccountAndRefresh(budgetID: String, name: String, offbudget: Bool) async throws

    @MainActor
    func syncBankAccountAndRefresh(budgetID: String, accountID: String) async throws -> LoadedAccountTransactions?

    @MainActor
    func syncBankAccountAndFindNewTransactions(
        budgetID: String,
        account: ActualAccount
    ) async throws -> BackgroundAccountRefreshResult

    @MainActor
    func reconcileAccountAndRefresh(
        budgetID: String,
        accountID: String,
        statementBalance: Int
    ) async throws -> APIAccountReconciliationResult
}

/// Result of a background bank-sync pass: the account checked and any newly appeared transaction IDs.
struct BackgroundAccountRefreshResult: Hashable, Sendable {
    let account: ActualAccount
    let newTransactionIDs: [String]
}
