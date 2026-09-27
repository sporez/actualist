import Foundation

/// Resolves menu intent inputs from the current store snapshot, rather than the
/// account value retained by a navigation destination before a rename or reopen.
struct AccountLifecycleMenuContext {
    let identity: AccountLifecycleIdentity
    let account: AccountLifecycleAccount
    let accounts: [AccountLifecycleAccount]

    init?(budgetID: String?, accountID: String, accounts: [ActualAccount]) {
        guard let budgetID else { return nil }
        let projected = accounts.map {
            AccountLifecycleAccount(
                id: $0.id, name: $0.name, offBudget: $0.offbudget,
                isClosed: $0.closed, accountGroupID: $0.accountGroupId
            )
        }
        guard let account = projected.first(where: { $0.id == accountID }) else { return nil }
        identity = AccountLifecycleIdentity(budgetID: budgetID, accountID: accountID)
        self.account = account
        self.accounts = projected
    }
}
