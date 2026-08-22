import AppIntents
import Foundation

struct GetAccountsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Accounts"
    static var description = IntentDescription("Returns accounts in the selected budget.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Include Closed", default: false)
    var includeClosed: Bool

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get Accounts") {
            \.$includeClosed
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[AccountEntity]> & ProvidesDialog {
        let accounts = try await session.accounts(includeClosed: includeClosed)
        let dialog: IntentDialog
        switch accounts.count {
        case 0:
            dialog = "No accounts in the selected budget."
        case 1:
            dialog = "1 account."
        default:
            dialog = IntentDialog("\(accounts.count) accounts.")
        }
        return .result(value: accounts, dialog: dialog)
    }
}

struct GetAccountIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Account"
    static var description = IntentDescription("Returns one account, including its balance.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Account")
    var account: AccountEntity

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$account)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<AccountEntity> & ProvidesDialog {
        let resolved = try await session.account(id: account.id)
        let spoken = ShortcutMoney.spoken(resolved.balance)
        return .result(value: resolved, dialog: IntentDialog("\(resolved.name) has \(spoken)."))
    }
}

struct GetAccountBalanceIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Account Balance"
    static var description = IntentDescription("Returns the balance of one account.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Account")
    var account: AccountEntity

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$account) balance")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentCurrencyAmount> & ProvidesDialog {
        let resolved = try await session.account(id: account.id)
        let amount = resolved.balance ?? ShortcutMoney.intentAmount(minorUnits: 0)
        let spoken = ShortcutMoney.spoken(amount)
        return .result(value: amount, dialog: IntentDialog("\(resolved.name) has \(spoken)."))
    }
}

struct GetAccountTransactionsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Account Transactions"
    static var description = IntentDescription("Returns recent transactions for one account.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Account")
    var account: AccountEntity

    @Parameter(title: "Limit", default: 25)
    var limit: Int

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get transactions in \(\.$account)") {
            \.$limit
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[TransactionEntity]> & ProvidesDialog {
        let transactions = try await session.transactions(accountID: account.id, limit: limit)
        return .result(
            value: transactions,
            dialog: IntentDialog("\(transactions.count) transactions in \(account.name).")
        )
    }
}
