import AppIntents
import Foundation

struct OpenBudgetIntent: ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Open Budget"
    static var description = IntentDescription(
        "Opens the Budget tab.",
        categoryName: "Budget"
    )
    static var openAppWhenRun = true

    @Dependency
    var session: ShortcutsBudgetSession

    func perform() async throws -> some IntentResult {
        try await session.enqueueRoute(.tab(.budget))
        return .result()
    }
}

struct OpenAccountsIntent: ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Open Accounts"
    static var description = IntentDescription(
        "Opens the Accounts tab.",
        categoryName: "Accounts"
    )
    static var openAppWhenRun = true

    @Dependency
    var session: ShortcutsBudgetSession

    func perform() async throws -> some IntentResult {
        try await session.enqueueRoute(.tab(.accounts))
        return .result()
    }
}

struct OpenSpendingIntent: ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Open Spending"
    static var description = IntentDescription(
        "Opens the Spending tab.",
        categoryName: "Transactions"
    )
    static var openAppWhenRun = true

    @Dependency
    var session: ShortcutsBudgetSession

    func perform() async throws -> some IntentResult {
        try await session.enqueueRoute(.tab(.spending))
        return .result()
    }
}

struct OpenReportsIntent: ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Open Reports"
    static var description = IntentDescription(
        "Opens the Reports tab.",
        categoryName: "Reports"
    )
    static var openAppWhenRun = true

    @Dependency
    var session: ShortcutsBudgetSession

    func perform() async throws -> some IntentResult {
        try await session.enqueueRoute(.tab(.reports))
        return .result()
    }
}

struct OpenAccountIntent: ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Open Account"
    static var description = IntentDescription(
        "Opens one account in Actualist.",
        categoryName: "Accounts"
    )
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Account")
    var account: AccountEntity

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$account)")
    }

    func perform() async throws -> some IntentResult {
        _ = try await session.prepare()
        try await session.enqueueRoute(.account(id: account.id))
        return .result()
    }
}

struct OpenCategoryIntent: ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Open Category"
    static var description = IntentDescription(
        "Opens one category's month details.",
        categoryName: "Budget"
    )
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Category")
    var category: CategoryEntity

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$category)") {
            \.$month
        }
    }

    func perform() async throws -> some IntentResult {
        let loaded = try await session.loadedMonth(preferred: month?.id)
        try await session.enqueueRoute(.category(id: category.id, month: loaded.selectedMonth))
        return .result()
    }
}

struct OpenUncategorizedIntent: ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Open Uncategorized"
    static var description = IntentDescription(
        "Opens uncategorized transactions for a month.",
        categoryName: "Budget"
    )
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Open Uncategorized") {
            \.$month
        }
    }

    func perform() async throws -> some IntentResult {
        let loaded = try await session.loadedMonth(preferred: month?.id)
        try await session.enqueueRoute(.uncategorized(month: loaded.selectedMonth))
        return .result()
    }
}

struct OpenNewTransactionIntent: ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Open New Transaction"
    static var description = IntentDescription(
        "Opens the transaction editor with optional prefill. Does not write.",
        categoryName: "Transactions"
    )
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Account")
    var account: AccountEntity?

    @Parameter(title: "Amount")
    var amount: IntentCurrencyAmount?

    @Parameter(title: "Payee")
    var payee: PayeeEntity?

    @Parameter(title: "Payee Name")
    var payeeName: String?

    @Parameter(title: "Category")
    var category: CategoryEntity?

    @Parameter(title: "Notes")
    var notes: String?

    @Parameter(title: "Direction", default: ShortcutTransactionDirectionAppEnum.spend)
    var direction: ShortcutTransactionDirectionAppEnum

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Open New Transaction") {
            \.$account
            \.$amount
            \.$payee
            \.$payeeName
            \.$category
            \.$notes
            \.$direction
        }
    }

    func perform() async throws -> some IntentResult {
        _ = try await session.prepare()
        try await session.enqueueRoute(
            .newTransaction(
                ShortcutEditorPrefill(
                    accountID: account?.id,
                    amountMinorUnits: try amount.map { try ShortcutMoney.minorUnits(from: $0) },
                    payeeID: payee?.id,
                    payeeName: payeeName ?? payee?.name,
                    categoryID: category?.id,
                    categoryName: category?.name,
                    notes: notes,
                    direction: direction.commandDirection == .inflow ? .inflow : .spend
                )
            )
        )
        return .result()
    }
}
