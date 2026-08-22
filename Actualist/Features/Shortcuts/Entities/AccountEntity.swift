import AppIntents
import Foundation

struct AccountEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static var defaultQuery = AccountEntityQuery()

    var id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Balance")
    var balance: IntentCurrencyAmount?

    @Property(title: "Off-Budget")
    var offBudget: Bool

    @Property(title: "Closed")
    var closed: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: offBudget ? "Off-budget" : "On-budget"
        )
    }

    init(
        id: String,
        name: String,
        balance: IntentCurrencyAmount?,
        offBudget: Bool,
        closed: Bool
    ) {
        self.id = id
        self.name = name
        self.balance = balance
        self.offBudget = offBudget
        self.closed = closed
    }

    static func make(from display: AccountDisplay) -> AccountEntity {
        AccountEntity(
            id: display.account.id,
            name: display.account.name,
            balance: display.balance.map(ShortcutMoney.intentAmount(minorUnits:)),
            offBudget: display.account.offbudget,
            closed: display.account.closed
        )
    }
}

struct AccountEntityQuery: EntityQuery {
    @Dependency var session: ShortcutsBudgetSession

    func entities(for identifiers: [AccountEntity.ID]) async throws -> [AccountEntity] {
        let wanted = Set(identifiers)
        return try await session.accounts(includeClosed: true).filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AccountEntity] {
        try await session.accounts(includeClosed: false)
    }
}

extension AccountEntityQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [AccountEntity] {
        try await session.accounts(includeClosed: false, matching: string)
    }
}
