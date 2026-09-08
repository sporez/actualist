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

    @Property(title: "Budget Type")
    var budgetType: String

    @Property(title: "Projected Savings")
    var projectedSavings: IntentCurrencyAmount?

    @Property(title: "Actual Savings")
    var actualSavings: IntentCurrencyAmount?

    @Property(title: "Savings Label")
    var savingsLabel: String?

    @Property(title: "Savings")
    var savings: IntentCurrencyAmount?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(ReportCalendar.shortMonthTitle(month))",
            subtitle: "\(spokenSummary)"
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
        incomeAvailable: IntentCurrencyAmount?,
        budgetType: String = "Envelope",
        projectedSavings: IntentCurrencyAmount? = nil,
        actualSavings: IntentCurrencyAmount? = nil,
        savingsLabel: String? = nil,
        savings: IntentCurrencyAmount? = nil
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
        self.budgetType = budgetType
        self.projectedSavings = projectedSavings
        self.actualSavings = actualSavings
        self.savingsLabel = savingsLabel
        self.savings = savings
    }

    static func make(from loaded: LoadedBudgetMonth, currentMonth: String = WidgetMonthID.current()) -> BudgetSummaryEntity {
        let month = loaded.month
        let tracking = month.trackingSummary
        let headline = tracking?.headline(month: month.month, currentMonth: currentMonth)
        func amount(_ value: Int?) -> IntentCurrencyAmount? {
            value.map { ShortcutMoney.intentAmount(minorUnits: $0, currency: loaded.currency) }
        }
        return BudgetSummaryEntity(
            id: loaded.selectedMonth,
            month: loaded.selectedMonth,
            readyToAssign: tracking == nil ? amount(month.toBudget) : nil,
            totalBudgeted: ShortcutMoney.intentAmount(minorUnits: month.totalBudgeted, currency: loaded.currency),
            totalSpent: ShortcutMoney.intentAmount(minorUnits: month.totalSpent, currency: loaded.currency),
            totalIncome: ShortcutMoney.intentAmount(minorUnits: month.totalIncome, currency: loaded.currency),
            fromLastMonth: tracking == nil ? amount(month.fromLastMonth) : nil,
            forNextMonth: tracking == nil ? amount(month.forNextMonth) : nil,
            incomeAvailable: tracking == nil ? amount(month.incomeAvailable) : nil,
            budgetType: tracking == nil ? "Envelope" : "Tracking",
            projectedSavings: amount(tracking?.plannedSavings),
            actualSavings: amount(tracking?.actualSavings),
            savingsLabel: headline?.kind.title,
            savings: amount(headline?.amount)
        )
    }

    var spokenSummary: String {
        if let savingsLabel, let savings {
            return "\(savingsLabel): \(ShortcutMoney.spoken(savings))."
        }
        return "You have \(ShortcutMoney.spoken(readyToAssign)) ready to assign."
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
