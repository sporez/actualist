import AppIntents
import Foundation

struct OpenBudgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Budget"
    static var description = IntentDescription("Opens the Budget tab.")
    static var openAppWhenRun = true

    @Dependency
    var session: ShortcutsBudgetSession

    func perform() async throws -> some IntentResult {
        await session.enqueueRoute(.tab(.budget))
        return .result()
    }
}

struct OpenAccountsIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Accounts"
    static var description = IntentDescription("Opens the Accounts tab.")
    static var openAppWhenRun = true

    @Dependency
    var session: ShortcutsBudgetSession

    func perform() async throws -> some IntentResult {
        await session.enqueueRoute(.tab(.accounts))
        return .result()
    }
}

struct OpenSpendingIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Spending"
    static var description = IntentDescription("Opens the Spending tab.")
    static var openAppWhenRun = true

    @Dependency
    var session: ShortcutsBudgetSession

    func perform() async throws -> some IntentResult {
        await session.enqueueRoute(.tab(.spending))
        return .result()
    }
}

struct OpenReportsIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Reports"
    static var description = IntentDescription("Opens the Reports tab.")
    static var openAppWhenRun = true

    @Dependency
    var session: ShortcutsBudgetSession

    func perform() async throws -> some IntentResult {
        await session.enqueueRoute(.tab(.reports))
        return .result()
    }
}

struct OpenAccountIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Account"
    static var description = IntentDescription("Opens one account in Actualist.")
    static var openAppWhenRun = true

    @Parameter(title: "Account")
    var account: AccountEntity

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$account)")
    }

    func perform() async throws -> some IntentResult {
        _ = try await session.prepare()
        await session.enqueueRoute(.account(id: account.id))
        return .result()
    }
}

struct OpenCategoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Category"
    static var description = IntentDescription("Opens one category's month details.")
    static var openAppWhenRun = true

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
        await session.enqueueRoute(.category(id: category.id, month: loaded.selectedMonth))
        return .result()
    }
}

struct OpenUncategorizedIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Uncategorized"
    static var description = IntentDescription("Opens uncategorized transactions for a month.")
    static var openAppWhenRun = true

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
        await session.enqueueRoute(.uncategorized(month: loaded.selectedMonth))
        return .result()
    }
}

struct OpenNewTransactionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open New Transaction"
    static var description = IntentDescription("Opens the transaction editor with optional prefill. Does not write.")
    static var openAppWhenRun = true

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
        await session.enqueueRoute(
            .newTransaction(
                ShortcutEditorPrefill(
                    accountID: account?.id,
                    amountMinorUnits: try amount.map { try ShortcutMoney.minorUnits(from: $0) },
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
