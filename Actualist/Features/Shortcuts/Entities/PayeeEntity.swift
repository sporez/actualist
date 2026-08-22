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

    var transferAccountID: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: String, name: String, isTransfer: Bool, transferAccountID: String? = nil) {
        self.id = id
        self.name = name
        self.isTransfer = isTransfer
        self.transferAccountID = transferAccountID
    }

    static func make(from payee: ManagedPayee) -> PayeeEntity {
        PayeeEntity(
            id: payee.id,
            name: payee.displayName,
            isTransfer: payee.isTransfer,
            transferAccountID: payee.transferAccountID
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
