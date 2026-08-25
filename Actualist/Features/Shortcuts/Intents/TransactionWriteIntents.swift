import AppIntents
import Foundation

enum ShortcutTransactionDirectionAppEnum: String, AppEnum {
    case spend
    case inflow

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Direction")
    static let caseDisplayRepresentations: [ShortcutTransactionDirectionAppEnum: DisplayRepresentation] = [
        .spend: "Spend",
        .inflow: "Inflow"
    ]

    var commandDirection: ShortcutTransactionDirection {
        switch self {
        case .spend: .spend
        case .inflow: .inflow
        }
    }
}

struct LogTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Transaction"
    static let description = IntentDescription(
        "Logs a transaction in the selected budget immediately.",
        categoryName: "Transactions"
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Amount")
    var amount: IntentCurrencyAmount

    @Parameter(title: "Account")
    var account: AccountEntity?

    @Parameter(title: "Direction", default: ShortcutTransactionDirectionAppEnum.spend)
    var direction: ShortcutTransactionDirectionAppEnum

    @Parameter(title: "Payee")
    var payee: PayeeEntity?

    @Parameter(title: "Payee Name")
    var payeeName: String?

    @Parameter(title: "Category")
    var category: CategoryEntity?

    @Parameter(title: "Notes")
    var notes: String?

    @Parameter(title: "Date")
    var date: Date?

    @Parameter(title: "Cleared", default: false)
    var cleared: Bool

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount)") {
            \.$account
            \.$direction
            \.$payee
            \.$payeeName
            \.$category
            \.$notes
            \.$date
            \.$cleared
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<TransactionEntity> & ProvidesDialog {
        let transaction = try await ShortcutTransactionCommand.log(
            .init(
                amountMinorUnits: try await session.minorUnits(from: amount),
                direction: direction.commandDirection,
                accountID: account?.id,
                payeeID: payee?.id,
                payeeName: payeeName ?? payee?.name,
                categoryID: category?.id,
                notes: notes,
                date: date,
                cleared: cleared
            ),
            session: session
        )
        let spoken = ShortcutMoney.spoken(transaction.amount)
        return .result(value: transaction, dialog: IntentDialog("Logged \(spoken) for \(transaction.payee)."))
    }
}

struct LogTransferIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Transfer"
    static let description = IntentDescription(
        "Transfers money between two accounts immediately.",
        categoryName: "Transactions"
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "From Account")
    var fromAccount: AccountEntity

    @Parameter(title: "To Account")
    var toAccount: AccountEntity

    @Parameter(title: "Amount")
    var amount: IntentCurrencyAmount

    @Parameter(title: "Date")
    var date: Date?

    @Parameter(title: "Notes")
    var notes: String?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Transfer \(\.$amount) from \(\.$fromAccount) to \(\.$toAccount)") {
            \.$date
            \.$notes
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<TransactionEntity> & ProvidesDialog {
        let transaction = try await ShortcutTransactionCommand.transfer(
            fromAccountID: fromAccount.id,
            toAccountID: toAccount.id,
            amountMinorUnits: try await session.minorUnits(from: amount),
            date: date,
            notes: notes,
            session: session
        )
        let spoken = ShortcutMoney.spoken(transaction.amount)
        return .result(
            value: transaction,
            dialog: IntentDialog("Transferred \(spoken) from \(fromAccount.name) to \(toAccount.name).")
        )
    }
}

struct UpdateTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Update Transaction"
    static let description = IntentDescription(
        "Updates a transaction immediately.",
        categoryName: "Transactions"
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Transaction")
    var transaction: TransactionEntity

    @Parameter(title: "Amount")
    var amount: IntentCurrencyAmount?

    @Parameter(title: "Direction")
    var direction: ShortcutTransactionDirectionAppEnum?

    @Parameter(title: "Account")
    var account: AccountEntity?

    @Parameter(title: "Payee")
    var payee: PayeeEntity?

    @Parameter(title: "Payee Name")
    var payeeName: String?

    @Parameter(title: "Category")
    var category: CategoryEntity?

    @Parameter(title: "Notes")
    var notes: String?

    @Parameter(title: "Date")
    var date: Date?

    @Parameter(title: "Cleared")
    var cleared: Bool?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Update \(\.$transaction)") {
            \.$amount
            \.$direction
            \.$account
            \.$payee
            \.$payeeName
            \.$category
            \.$notes
            \.$date
            \.$cleared
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<TransactionEntity> & ProvidesDialog {
        let updated = try await ShortcutTransactionCommand.update(
            .init(
                transactionID: transaction.id,
                amountMinorUnits: try await {
                    guard let amount else { return nil as Int? }
                    return try await session.minorUnits(from: amount)
                }(),
                direction: direction?.commandDirection,
                accountID: account?.id,
                payeeID: payee?.id,
                payeeName: payeeName ?? payee?.name,
                categoryID: category?.id,
                notes: notes,
                date: date,
                cleared: cleared
            ),
            session: session
        )
        let spoken = ShortcutMoney.spoken(updated.amount)
        return .result(value: updated, dialog: IntentDialog("Updated \(updated.payee) · \(spoken)."))
    }
}

struct CategorizeTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Categorize Transaction"
    static let description = IntentDescription(
        "Sets a transaction's category immediately.",
        categoryName: "Transactions"
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Transaction")
    var transaction: TransactionEntity

    @Parameter(title: "Category")
    var category: CategoryEntity

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Categorize \(\.$transaction) as \(\.$category)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<TransactionEntity> & ProvidesDialog {
        let updated = try await ShortcutTransactionCommand.categorize(
            transactionID: transaction.id,
            categoryID: category.id,
            session: session
        )
        return .result(value: updated, dialog: IntentDialog("Categorized \(updated.payee) as \(category.name)."))
    }
}

struct SetTransactionClearedIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Transaction Cleared"
    static let description = IntentDescription(
        "Marks a transaction cleared or uncleared immediately.",
        categoryName: "Transactions"
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Transaction")
    var transaction: TransactionEntity

    @Parameter(title: "Cleared")
    var cleared: Bool

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$transaction) cleared to \(\.$cleared)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<TransactionEntity> & ProvidesDialog {
        let updated = try await ShortcutTransactionCommand.setCleared(
            transactionID: transaction.id,
            cleared: cleared,
            session: session
        )
        let state = cleared ? "cleared" : "uncleared"
        return .result(value: updated, dialog: IntentDialog("Marked \(updated.payee) \(state)."))
    }
}

struct DeleteTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Transaction"
    static let description = IntentDescription(
        "Deletes a transaction immediately.",
        categoryName: "Transactions"
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Transaction")
    var transaction: TransactionEntity

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Delete \(\.$transaction)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<TransactionEntity> & ProvidesDialog {
        let deleted = try await ShortcutTransactionCommand.delete(
            transactionID: transaction.id,
            session: session
        )
        let spoken = ShortcutMoney.spoken(deleted.amount)
        return .result(value: deleted, dialog: IntentDialog("Deleted \(deleted.payee) · \(spoken)."))
    }
}

struct ImportTransactionFromTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Import Transaction from Text"
    static let description = IntentDescription(
        "Parses text and logs the transaction immediately.",
        categoryName: "Transactions"
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Text")
    var text: String

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Import transaction from \(\.$text)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<TransactionEntity> & ProvidesDialog {
        let transaction = try await ShortcutTransactionCommand.importFromText(text, session: session)
        let spoken = ShortcutMoney.spoken(transaction.amount)
        return .result(value: transaction, dialog: IntentDialog("Logged \(spoken) for \(transaction.payee)."))
    }
}
