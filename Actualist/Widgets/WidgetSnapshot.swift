import Foundation

struct WidgetSnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var budgetID: String
    var budgetName: String
    var month: String
    var privacyEnabled: Bool
    var updatedAt: Date
    var categories: [WidgetCategorySnapshot]

    static let currentSchemaVersion = 1

    func hasSameDisplayContent(as other: WidgetSnapshot) -> Bool {
        schemaVersion == other.schemaVersion
            && budgetID == other.budgetID
            && budgetName == other.budgetName
            && month == other.month
            && privacyEnabled == other.privacyEnabled
            && categories == other.categories
    }
}

struct WidgetCategorySnapshot: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var displayName: String
    var group: String
    var isHidden: Bool
    var availableMinorUnits: Int
    var formattedAvailable: String
}
