import AppIntents
import Foundation

struct GetTransactionsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Transactions"
    static var description = IntentDescription("Returns recent or matching transactions in the selected budget.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Account")
    var account: AccountEntity?

    @Parameter(title: "Search")
    var search: String?

    @Parameter(title: "Limit", default: 25)
    var limit: Int

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get Transactions") {
            \.$account
            \.$search
            \.$limit
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[TransactionEntity]> & ProvidesDialog {
        let transactions = try await session.transactions(
            accountID: account?.id,
            search: search,
            limit: limit
        )
        return .result(value: transactions, dialog: IntentDialog("\(transactions.count) transactions."))
    }
}

struct GetTransactionIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Transaction"
    static var description = IntentDescription("Returns one transaction.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Transaction")
    var transaction: TransactionEntity

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$transaction)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<TransactionEntity> & ProvidesDialog {
        let resolved = try await session.transaction(id: transaction.id)
        let spoken = ShortcutMoney.spoken(resolved.amount)
        return .result(
            value: resolved,
            dialog: IntentDialog("\(resolved.payee) · \(spoken).")
        )
    }
}
