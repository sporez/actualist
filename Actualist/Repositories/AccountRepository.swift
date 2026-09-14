import Foundation

protocol AccountRepositoryProtocol: Sendable {
    @MainActor
    func accountDisplays(budgetID: String) -> [AccountDisplay]

    @MainActor
    func accountGroups(budgetID: String) -> [ActualAccountGroup]

    @MainActor
    func accountGroupManagementEnabled(budgetID: String) -> Bool

    @MainActor
    func refreshAccountsWithBalances(budgetID: String) async throws

    @MainActor
    func accountReconciliationSnapshot(
        budgetID: String,
        accountID: String
    ) async throws -> AccountReconciliationSnapshot

    @MainActor
    func createReconciliationAdjustmentAndRefresh(
        budgetID: String,
        accountID: String,
        targetBalance: Int
    ) async throws -> AccountReconciliationMutationResult

    @MainActor
    func finishReconciliationAndRefresh(
        budgetID: String,
        accountID: String,
        targetBalance: Int
    ) async throws -> AccountReconciliationMutationResult

    @MainActor
    func exitReconciliationAndRefresh(
        budgetID: String,
        accountID: String
    ) async throws -> AccountReconciliationMutationResult

    @MainActor
    func unlockReconciledTransactionAndRefresh(
        budgetID: String,
        accountID: String,
        transactionID: String
    ) async throws -> AccountReconciliationMutationResult

    @MainActor
    func createAccountAndRefresh(budgetID: String, name: String, offbudget: Bool) async throws

    @MainActor
    func createAccountGroupAndRefresh(budgetID: String, name: String) async throws

    @MainActor
    func renameAccountGroupAndRefresh(budgetID: String, groupID: String, name: String) async throws

    @MainActor
    func deleteAccountGroupAndRefresh(budgetID: String, groupID: String) async throws

    @MainActor
    func moveAccountToGroupAndRefresh(
        budgetID: String,
        accountID: String,
        groupID: String?
    ) async throws

    @MainActor
    func moveAccountGroupAndRefresh(
        budgetID: String,
        groupID: String,
        beforeGroupID: String?
    ) async throws
}

struct BackgroundAccountRefreshResult: Hashable, Sendable {
    let account: ActualAccount
    let newTransactionIDs: [String]
}
