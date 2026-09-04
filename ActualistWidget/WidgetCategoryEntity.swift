import AppIntents
import Foundation

struct WidgetCategoryEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Category"
    static let defaultQuery = WidgetCategoryEntityQuery()

    var id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Group")
    var group: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: group.isEmpty ? nil : "\(group)"
        )
    }

    init(id: String, name: String, group: String) {
        self.id = id
        self.name = name
        self.group = group
    }

    init(_ category: WidgetCategorySnapshot) {
        self.init(
            id: category.id,
            name: category.displayName,
            group: category.group
        )
    }
}

struct WidgetCategoryEntityQuery: EntityQuery {
    func entities(for identifiers: [WidgetCategoryEntity.ID]) async throws -> [WidgetCategoryEntity] {
        let byID = Dictionary(
            uniqueKeysWithValues: categories.map { ($0.id, WidgetCategoryEntity($0)) }
        )
        return identifiers.compactMap { byID[$0] }
    }

    func suggestedEntities() async throws -> [WidgetCategoryEntity] {
        categories
            .filter { !$0.isHidden }
            .map(WidgetCategoryEntity.init)
    }

    private var categories: [WidgetCategorySnapshot] {
        WidgetSnapshotStore.live.load()?.categories ?? []
    }
}

extension WidgetCategoryEntityQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [WidgetCategoryEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return try await suggestedEntities()
        }
        return categories.compactMap { category in
            guard !category.isHidden else {
                return nil
            }
            let matchesName = category.displayName.localizedCaseInsensitiveContains(query)
            let matchesGroup = category.group.localizedCaseInsensitiveContains(query)
            return matchesName || matchesGroup ? WidgetCategoryEntity(category) : nil
        }
    }
}
