import AppIntents
import Foundation

struct CategoryEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Category"
    static let defaultQuery = CategoryEntityQuery()

    var id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Group")
    var group: String

    @Property(title: "Available")
    var available: IntentCurrencyAmount?

    @Property(title: "Budgeted")
    var budgeted: IntentCurrencyAmount?

    @Property(title: "Spent")
    var spent: IntentCurrencyAmount?

    @Property(title: "Carryover")
    var carryover: Bool

    @Property(title: "Income")
    var isIncome: Bool

    @Property(title: "Hidden")
    var isHidden: Bool

    @Property(title: "Budget Type")
    var budgetType: String

    @Property(title: "Balance")
    var balance: IntentCurrencyAmount?

    @Property(title: "Received")
    var received: IntentCurrencyAmount?

    var spokenSummary: String {
        let metric: (amount: IntentCurrencyAmount?, label: String)
        if budgetType == "Tracking" {
            metric = isIncome ? (received, "received") : (balance, "balance")
        } else {
            metric = (available, "available")
        }
        return "\(name) has \(ShortcutMoney.spoken(metric.amount)) \(metric.label)."
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: group.isEmpty ? nil : "\(group)"
        )
    }

    init(
        id: String,
        name: String,
        group: String,
        available: IntentCurrencyAmount?,
        budgeted: IntentCurrencyAmount?,
        spent: IntentCurrencyAmount?,
        carryover: Bool,
        isIncome: Bool,
        isHidden: Bool,
        budgetType: String = "Envelope",
        balance: IntentCurrencyAmount? = nil,
        received: IntentCurrencyAmount? = nil
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.available = available
        self.budgeted = budgeted
        self.spent = spent
        self.carryover = carryover
        self.isIncome = isIncome
        self.isHidden = isHidden
        self.budgetType = budgetType
        self.balance = balance
        self.received = received
    }

    static func make(
        from category: BudgetMonthCategory,
        groupName: String,
        currency: BudgetCurrency? = nil,
        isHidden: Bool? = nil,
        isTrackingBudget: Bool = false
    ) -> CategoryEntity {
        CategoryEntity(
            id: category.id,
            name: category.name,
            group: groupName,
            available: isTrackingBudget ? nil : ShortcutMoney.intentAmount(minorUnits: category.balance, currency: currency),
            budgeted: ShortcutMoney.intentAmount(minorUnits: category.budgeted, currency: currency),
            spent: isTrackingBudget && category.isIncome ? nil : ShortcutMoney.intentAmount(minorUnits: category.spent, currency: currency),
            carryover: category.carryover,
            isIncome: category.isIncome,
            isHidden: isHidden ?? (category.hidden ?? false),
            budgetType: isTrackingBudget ? "Tracking" : "Envelope",
            balance: isTrackingBudget && !category.isIncome
                ? ShortcutMoney.intentAmount(minorUnits: category.balance, currency: currency) : nil,
            received: isTrackingBudget && category.isIncome
                ? ShortcutMoney.intentAmount(minorUnits: category.spent, currency: currency) : nil
        )
    }
}

struct CategoryEntityQuery: EntityQuery {
    @Dependency var session: ShortcutsBudgetSession

    func entities(for identifiers: [CategoryEntity.ID]) async throws -> [CategoryEntity] {
        let wanted = Set(identifiers)
        return try await session.categories(includeHidden: true, includeIncome: true)
            .filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [CategoryEntity] {
        try await session.categories(includeHidden: false)
    }
}

extension CategoryEntityQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [CategoryEntity] {
        try await session.categories(includeHidden: false, matching: string)
    }
}
