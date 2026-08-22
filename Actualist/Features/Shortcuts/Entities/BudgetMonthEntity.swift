import AppIntents
import Foundation

struct BudgetMonthEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Budget Month"
    static var defaultQuery = BudgetMonthEntityQuery()

    var id: String

    @Property(title: "Name")
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    static func make(monthID: String) -> BudgetMonthEntity {
        BudgetMonthEntity(
            id: monthID,
            name: ReportCalendar.shortMonthTitle(monthID)
        )
    }
}

struct BudgetMonthEntityQuery: EntityQuery {
    @Dependency var session: ShortcutsBudgetSession

    func entities(for identifiers: [BudgetMonthEntity.ID]) async throws -> [BudgetMonthEntity] {
        let wanted = Set(identifiers)
        return try await session.months().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [BudgetMonthEntity] {
        try await session.months()
    }

    func defaultResult() async -> BudgetMonthEntity? {
        try? await session.loadedMonth().selectedMonth.displayMonthEntity
    }
}

extension BudgetMonthEntityQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [BudgetMonthEntity] {
        try await session.months(matching: string)
    }
}

private extension String {
    var displayMonthEntity: BudgetMonthEntity {
        BudgetMonthEntity.make(monthID: self)
    }
}
