import Foundation

protocol AccountRepositoryProtocol: Sendable {
    @MainActor
    func accountDisplays(budgetID: String) -> [AccountDisplay]

    @MainActor
    func refreshAccountsWithBalances(budgetID: String) async throws

    @MainActor
    func createAccountAndRefresh(budgetID: String, name: String, offbudget: Bool) async throws

    @MainActor
    func reconcileAccountAndRefresh(
        budgetID: String,
        accountID: String,
        statementBalance: Int
    ) async throws -> AccountReconciliationResult
}

struct BackgroundAccountRefreshResult: Hashable, Sendable {
    let account: ActualAccount
    let newTransactionIDs: [String]
}
