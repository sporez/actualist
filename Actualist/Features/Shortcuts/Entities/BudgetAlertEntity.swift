import AppIntents
import Foundation

struct BudgetAlertEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Budget Alert"
    static var defaultQuery = BudgetAlertEntityQuery()

    var id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Severity")
    var severity: String

    @Property(title: "Amount")
    var amount: IntentCurrencyAmount?

    @Property(title: "Count")
    var count: Int?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: subtitle)
    }

    init(
        id: String,
        title: String,
        severity: String,
        amount: IntentCurrencyAmount?,
        count: Int?
    ) {
        self.id = id
        self.title = title
        self.severity = severity
        self.amount = amount
        self.count = count
    }

    static func make(from alert: BudgetMonthAlert, month: String) -> BudgetAlertEntity {
        BudgetAlertEntity(
            id: "\(month)|\(alert.kind)|\(alert.title)",
            title: alert.title,
            severity: alert.severity,
            amount: alert.amount.map(ShortcutMoney.intentAmount(minorUnits:)),
            count: alert.count
        )
    }

    private var subtitle: LocalizedStringResource? {
        if let count {
            return "\(count)"
        }
        if let amount {
            return "\(Money(minorUnits: (try? ShortcutMoney.minorUnits(from: amount)) ?? 0).formatted())"
        }
        return nil
    }
}

struct BudgetAlertEntityQuery: EntityQuery {
    @Dependency var session: ShortcutsBudgetSession

    func entities(for identifiers: [BudgetAlertEntity.ID]) async throws -> [BudgetAlertEntity] {
        let wanted = Set(identifiers)
        return try await session.budgetAlerts().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [BudgetAlertEntity] {
        try await session.budgetAlerts()
    }
}
