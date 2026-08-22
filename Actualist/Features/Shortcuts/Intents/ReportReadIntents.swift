import AppIntents
import Foundation

struct GetNetWorthIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Net Worth"
    static var description = IntentDescription("Returns net worth and the change over the report range.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get Net Worth") {
            \.$month
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentCurrencyAmount> & ProvidesDialog {
        let dashboard = try await session.reportsDashboard(month: month?.id)
        let amount = ShortcutMoney.intentAmount(minorUnits: dashboard.netWorth.balance)
        let change = ShortcutMoney.spoken(minorUnits: dashboard.netWorth.change)
        let spoken = ShortcutMoney.spoken(amount)
        return .result(value: amount, dialog: IntentDialog("Net worth is \(spoken), change \(change)."))
    }
}

struct GetCashFlowIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Cash Flow"
    static var description = IntentDescription("Returns income, expenses, net, and uncategorized for a month.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get Cash Flow") {
            \.$month
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentCurrencyAmount> & ProvidesDialog {
        let dashboard = try await session.reportsDashboard(month: month?.id)
        let cashFlow = dashboard.cashFlow
        let net = ShortcutMoney.intentAmount(minorUnits: cashFlow.net)
        let income = ShortcutMoney.spoken(minorUnits: cashFlow.income)
        let expenses = ShortcutMoney.spoken(minorUnits: cashFlow.expenses)
        let spokenNet = ShortcutMoney.spoken(net)
        return .result(
            value: net,
            dialog: IntentDialog("Income \(income), expenses \(expenses), net \(spokenNet).")
        )
    }
}

struct GetBudgetOverviewIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Budget Overview"
    static var description = IntentDescription("Returns actual vs budgeted spending and the variance.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get Budget Overview") {
            \.$month
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentCurrencyAmount> & ProvidesDialog {
        let dashboard = try await session.reportsDashboard(month: month?.id)
        let overview = dashboard.budgetOverview
        let actual = ShortcutMoney.intentAmount(minorUnits: overview.actualExpenses)
        let budgeted = ShortcutMoney.spoken(minorUnits: overview.budgetedExpenses)
        let variance = ShortcutMoney.spoken(minorUnits: overview.variance)
        let spokenActual = ShortcutMoney.spoken(actual)
        return .result(
            value: actual,
            dialog: IntentDialog("Spent \(spokenActual) of \(budgeted) budgeted, variance \(variance).")
        )
    }
}
