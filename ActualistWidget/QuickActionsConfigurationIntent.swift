import AppIntents
import WidgetKit

struct QuickActionsConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Quick Actions"
    static let description = IntentDescription("Choose four actions and arrange them from left to right.")

    // Literal bounds are required by AppIntents; WidgetQuickActions owns runtime capacity.
    @Parameter(title: "Actions", size: [.systemMedium: .init(min: 4, max: 4)])
    var actions: [WidgetQuickActionEntity]?

    init() {
        actions = WidgetQuickActions.defaults.map(WidgetQuickActionEntity.init)
    }
}

struct WidgetQuickActionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Action"
    static let defaultQuery = WidgetQuickActionEntityQuery()

    let action: WidgetQuickAction
    var id: String { action.rawValue }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(action.title)",
            subtitle: "\(action.group.rawValue)",
            image: .init(systemName: action.symbol)
        )
    }

    init(_ action: WidgetQuickAction) {
        self.action = action
    }
}

struct WidgetQuickActionEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetQuickActionEntity] {
        identifiers.compactMap(WidgetQuickAction.init(rawValue:)).map(WidgetQuickActionEntity.init)
    }

    func suggestedEntities() async throws -> [WidgetQuickActionEntity] {
        WidgetQuickAction.matching().map(WidgetQuickActionEntity.init)
    }

    func entities(matching string: String) async throws -> [WidgetQuickActionEntity] {
        WidgetQuickAction.matching(string).map(WidgetQuickActionEntity.init)
    }
}
