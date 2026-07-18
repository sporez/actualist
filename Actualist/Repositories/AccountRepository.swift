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
    func reconcileAccountAndRefresh(
        budgetID: String,
        accountID: String,
        statementBalance: Int
    ) async throws -> APIAccountReconciliationResult
}

/// Result of a background CRDT refresh: the account checked and any newly appeared transaction IDs.
struct BackgroundAccountRefreshResult: Hashable, Sendable {
    let account: ActualAccount
    let newTransactionIDs: [String]
}
