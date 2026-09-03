import Foundation

enum WidgetAmountTone: String, Sendable, Equatable {
    case positive
    case zero
    case negative
}

struct WidgetCategoryBalanceRow: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var formattedAvailable: String
    var availableMinorUnits: Int
    var month: String

    var tone: WidgetAmountTone {
        if availableMinorUnits < 0 {
            return .negative
        }
        if availableMinorUnits == 0 {
            return .zero
        }
        return .positive
    }
}

enum WidgetCategoryBalanceProjection {
    static func rows(
        selectedIDs: [String],
        snapshot: WidgetSnapshot?,
        now: Date = Date(),
        calendar: Calendar? = nil,
        limit: Int
    ) -> [WidgetCategoryBalanceRow] {
        guard let snapshot else {
            return []
        }
        guard snapshot.month == WidgetMonthID.current(now: now, calendar: calendar) else {
            return []
        }
        let byID = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0) })
        return selectedIDs.compactMap { id in
            guard let category = byID[id] else {
                return nil
            }
            return WidgetCategoryBalanceRow(
                id: category.id,
                name: category.displayName,
                formattedAvailable: category.formattedAvailable,
                availableMinorUnits: category.availableMinorUnits,
                month: snapshot.month
            )
        }
        .prefix(max(limit, 0))
        .map { $0 }
    }

    static func visibleCount(for family: WidgetFamilySize) -> Int {
        switch family {
        case .medium: 3
        case .large: 8
        }
    }
}

enum WidgetFamilySize: String, Sendable {
    case medium
    case large
}

enum WidgetCategoryBalanceState: Equatable, Sendable {
    case placeholder
    case needsApp
    case needsCategories
    case categoriesUnavailable
    case ready

    static func resolve(
        selectedIDs: [String],
        snapshot: WidgetSnapshot?,
        rows: [WidgetCategoryBalanceRow],
        now: Date = Date(),
        calendar: Calendar? = nil
    ) -> WidgetCategoryBalanceState {
        if selectedIDs.isEmpty {
            return .needsCategories
        }
        guard let snapshot else {
            return .needsApp
        }
        if snapshot.month != WidgetMonthID.current(now: now, calendar: calendar) {
            return .needsApp
        }
        if rows.isEmpty {
            return .categoriesUnavailable
        }
        return .ready
    }
}
