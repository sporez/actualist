import AppIntents
import Foundation

struct PayeeEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Payee"
    static var defaultQuery = PayeeEntityQuery()

    var id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Transfer")
    var isTransfer: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: String, name: String, isTransfer: Bool) {
        self.id = id
        self.name = name
        self.isTransfer = isTransfer
    }

    static func make(from payee: ManagedPayee) -> PayeeEntity {
        PayeeEntity(
            id: payee.id,
            name: payee.displayName,
            isTransfer: payee.isTransfer
        )
    }
}

struct PayeeEntityQuery: EntityQuery {
    @Dependency var session: ShortcutsBudgetSession

    func entities(for identifiers: [PayeeEntity.ID]) async throws -> [PayeeEntity] {
        let wanted = Set(identifiers)
        return try await session.payees(includeTransfers: true).filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PayeeEntity] {
        try await session.payees(includeTransfers: false)
    }
}

extension PayeeEntityQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [PayeeEntity] {
        try await session.payees(includeTransfers: false, matching: string)
    }
}
