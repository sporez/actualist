import AppIntents
import Foundation

enum CategoryBalanceMetric: String, AppEnum {
    case available
    case budgeted
    case spent

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Category Metric")
    static var caseDisplayRepresentations: [CategoryBalanceMetric: DisplayRepresentation] = [
        .available: "Available",
        .budgeted: "Budgeted",
        .spent: "Spent"
    ]
}

struct GetCategoriesIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Categories"
    static var description = IntentDescription(
        "Returns categories in the selected budget.",
        categoryName: "Budget"
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Include Hidden", default: false)
    var includeHidden: Bool

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get Categories") {
            \.$includeHidden
            \.$month
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[CategoryEntity]> & ProvidesDialog {
        let categories = try await session.categories(
            includeHidden: includeHidden,
            month: month?.id
        )
        return .result(value: categories, dialog: IntentDialog("\(categories.count) categories."))
    }
}

struct GetCategoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Category"
    static var description = IntentDescription(
        "Returns one category, including available, budgeted, and spent.",
        categoryName: "Budget"
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Category")
    var category: CategoryEntity

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$category)") {
            \.$month
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<CategoryEntity> & ProvidesDialog {
        let resolved = try await session.category(id: category.id, month: month?.id)
        let spoken = ShortcutMoney.spoken(resolved.available)
        return .result(value: resolved, dialog: IntentDialog("\(resolved.name) has \(spoken) available."))
    }
}

struct GetCategoryBalanceIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Category Balance"
    static var description = IntentDescription(
        "Returns available, budgeted, or spent for one category.",
        categoryName: "Budget"
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Category")
    var category: CategoryEntity

    @Parameter(title: "Metric", default: CategoryBalanceMetric.available)
    var metric: CategoryBalanceMetric

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$metric) in \(\.$category)") {
            \.$month
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentCurrencyAmount> & ProvidesDialog {
        let resolved = try await session.category(id: category.id, month: month?.id)
        let amount: IntentCurrencyAmount?
        let label: String
        switch metric {
        case .available:
            amount = resolved.available
            label = "available"
        case .budgeted:
            amount = resolved.budgeted
            label = "budgeted"
        case .spent:
            amount = resolved.spent
            label = "spent"
        }
        let value = amount ?? ShortcutMoney.intentAmount(minorUnits: 0)
        let spoken = ShortcutMoney.spoken(value)
        return .result(value: value, dialog: IntentDialog("\(resolved.name) has \(spoken) \(label)."))
    }
}

struct GetPayeesIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Payees"
    static var description = IntentDescription(
        "Returns payees in the selected budget.",
        categoryName: "Transactions"
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Include Transfers", default: false)
    var includeTransfers: Bool

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get Payees") {
            \.$includeTransfers
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[PayeeEntity]> & ProvidesDialog {
        let payees = try await session.payees(includeTransfers: includeTransfers)
        return .result(value: payees, dialog: IntentDialog("\(payees.count) payees."))
    }
}

struct GetReadyToAssignIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Ready to Assign"
    static var description = IntentDescription(
        "Returns the amount ready to assign for a budget month.",
        categoryName: "Budget"
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get Ready to Assign") {
            \.$month
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentCurrencyAmount> & ProvidesDialog {
        let summary = try await session.budgetSummary(month: month?.id)
        let amount = summary.readyToAssign ?? ShortcutMoney.intentAmount(minorUnits: 0)
        let spoken = ShortcutMoney.spoken(amount)
        return .result(value: amount, dialog: IntentDialog("You have \(spoken) ready to assign."))
    }
}

struct GetBudgetSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Budget Summary"
    static var description = IntentDescription(
        "Returns ready to assign and month totals.",
        categoryName: "Budget"
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get Budget Summary") {
            \.$month
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<BudgetSummaryEntity> & ProvidesDialog {
        let summary = try await session.budgetSummary(month: month?.id)
        let spoken = ShortcutMoney.spoken(summary.readyToAssign)
        return .result(value: summary, dialog: IntentDialog("You have \(spoken) ready to assign."))
    }
}

struct GetOverspentCategoriesIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Overspent Categories"
    static var description = IntentDescription(
        "Returns visible expense categories that are overspent.",
        categoryName: "Budget"
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get Overspent Categories") {
            \.$month
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[CategoryEntity]> & ProvidesDialog {
        let categories = try await session.overspentCategories(month: month?.id)
        return .result(value: categories, dialog: IntentDialog("\(categories.count) overspent categories."))
    }
}

struct GetUncategorizedTransactionsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Uncategorized Transactions"
    static var description = IntentDescription(
        "Returns uncategorized transactions for a budget month.",
        categoryName: "Budget"
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Parameter(title: "Limit", default: 25)
    var limit: Int

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get Uncategorized Transactions") {
            \.$month
            \.$limit
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[TransactionEntity]> & ProvidesDialog {
        let transactions = try await session.uncategorizedTransactions(month: month?.id, limit: limit)
        return .result(value: transactions, dialog: IntentDialog("\(transactions.count) uncategorized transactions."))
    }
}

struct GetUncategorizedCountIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Uncategorized Count"
    static var description = IntentDescription(
        "Returns how many transactions are uncategorized in a month.",
        categoryName: "Budget"
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get Uncategorized Count") {
            \.$month
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let count = try await session.uncategorizedCount(month: month?.id)
        return .result(value: count, dialog: IntentDialog("\(count) uncategorized transactions."))
    }
}

struct GetBudgetAlertsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Budget Alerts"
    static var description = IntentDescription(
        "Returns ready-to-assign, overspent, and uncategorized alerts.",
        categoryName: "Budget"
    )
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get Budget Alerts") {
            \.$month
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[BudgetAlertEntity]> & ProvidesDialog {
        let alerts = try await session.budgetAlerts(month: month?.id)
        return .result(value: alerts, dialog: IntentDialog("\(alerts.count) budget alerts."))
    }
}
