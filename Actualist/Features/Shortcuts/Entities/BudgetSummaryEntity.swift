import AppIntents
import Foundation

struct BudgetSummaryEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Budget Summary"
    static let defaultQuery = BudgetSummaryEntityQuery()

    var id: String

    @Property(title: "Month")
    var month: String

    @Property(title: "Ready to Assign")
    var readyToAssign: IntentCurrencyAmount?

    @Property(title: "Total Budgeted")
    var totalBudgeted: IntentCurrencyAmount?

    @Property(title: "Total Spent")
    var totalSpent: IntentCurrencyAmount?

    @Property(title: "Total Income")
    var totalIncome: IntentCurrencyAmount?

    @Property(title: "From Last Month")
    var fromLastMonth: IntentCurrencyAmount?

    @Property(title: "For Next Month")
    var forNextMonth: IntentCurrencyAmount?

    @Property(title: "Income Available")
    var incomeAvailable: IntentCurrencyAmount?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(ReportCalendar.shortMonthTitle(month))",
            subtitle: readyToAssignSubtitle
        )
    }

    init(
        id: String,
        month: String,
        readyToAssign: IntentCurrencyAmount?,
        totalBudgeted: IntentCurrencyAmount?,
        totalSpent: IntentCurrencyAmount?,
        totalIncome: IntentCurrencyAmount?,
        fromLastMonth: IntentCurrencyAmount?,
        forNextMonth: IntentCurrencyAmount?,
        incomeAvailable: IntentCurrencyAmount?
    ) {
        self.id = id
        self.month = month
        self.readyToAssign = readyToAssign
        self.totalBudgeted = totalBudgeted
        self.totalSpent = totalSpent
        self.totalIncome = totalIncome
        self.fromLastMonth = fromLastMonth
        self.forNextMonth = forNextMonth
        self.incomeAvailable = incomeAvailable
    }

    static func make(from loaded: LoadedBudgetMonth) -> BudgetSummaryEntity {
        let month = loaded.month
        return BudgetSummaryEntity(
            id: loaded.selectedMonth,
            month: loaded.selectedMonth,
            readyToAssign: ShortcutMoney.intentAmount(minorUnits: month.toBudget, currency: loaded.currency),
            totalBudgeted: ShortcutMoney.intentAmount(minorUnits: month.totalBudgeted, currency: loaded.currency),
            totalSpent: ShortcutMoney.intentAmount(minorUnits: month.totalSpent, currency: loaded.currency),
            totalIncome: ShortcutMoney.intentAmount(minorUnits: month.totalIncome, currency: loaded.currency),
            fromLastMonth: ShortcutMoney.intentAmount(minorUnits: month.fromLastMonth, currency: loaded.currency),
            forNextMonth: ShortcutMoney.intentAmount(minorUnits: month.forNextMonth, currency: loaded.currency),
            incomeAvailable: ShortcutMoney.intentAmount(minorUnits: month.incomeAvailable, currency: loaded.currency)
        )
    }

    private var readyToAssignSubtitle: LocalizedStringResource {
        let spoken = readyToAssign.map {
            ShortcutMoney.spoken($0, currency: BudgetCurrency.catalog(code: $0.currencyCode))
        } ?? "—"
        return "Ready to assign \(spoken)"
    }
}

struct BudgetSummaryEntityQuery: EntityQuery {
    @Dependency var session: ShortcutsBudgetSession

    func entities(for identifiers: [BudgetSummaryEntity.ID]) async throws -> [BudgetSummaryEntity] {
        let wanted = Set(identifiers)
        var summaries: [BudgetSummaryEntity] = []
        for monthID in wanted {
            summaries.append(try await session.budgetSummary(month: monthID))
        }
        return summaries
    }

    func suggestedEntities() async throws -> [BudgetSummaryEntity] {
        [try await session.budgetSummary()]
    }

    func defaultResult() async -> BudgetSummaryEntity? {
        try? await session.budgetSummary()
    }
}
