import Foundation

struct AccountRepository: Sendable {
    let client: ActualAPIClient

    func accountsWithBalances(budgetID: String) async throws -> [AccountDisplay] {
        let apiAccounts = try await client.accounts(budgetID: budgetID)
        var displays: [AccountDisplay] = []

        for account in apiAccounts {
            let balance = try? await client.balance(budgetID: budgetID, accountID: account.id)
            displays.append(AccountDisplay(account: account, balance: balance))
        }

        return displays
    }
}
