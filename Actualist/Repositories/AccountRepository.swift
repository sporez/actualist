import Foundation

protocol AccountRepositoryProtocol: Sendable {
    @MainActor
    func accountDisplays(budgetID: String) -> [AccountDisplay]

    @MainActor
    func accountGroups(budgetID: String) -> [ActualAccountGroup]

    @MainActor
    func refreshAccountsWithBalances(budgetID: String) async throws

    @MainActor
    func createAccountAndRefresh(
        budgetID: String,
        name: String,
        offbudget: Bool,
        actionSource: BudgetActionSource
    ) async throws

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

extension AccountRepositoryProtocol {
    @MainActor
    func createAccountAndRefresh(budgetID: String, name: String, offbudget: Bool) async throws {
        try await createAccountAndRefresh(
            budgetID: budgetID,
            name: name,
            offbudget: offbudget,
            actionSource: .ui
        )
    }
}

struct BackgroundAccountRefreshResult: Hashable, Sendable {
    let account: ActualAccount
    let newTransactionIDs: [String]
}
