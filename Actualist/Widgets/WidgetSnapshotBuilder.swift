import Foundation

enum WidgetSnapshotBuilder {
    static func make(
        budgetID: String,
        budgetName: String,
        month: BudgetMonth,
        currency: BudgetCurrency,
        privacyEnabled: Bool,
        now: Date = Date()
    ) -> WidgetSnapshot {
        let displayMonth = BudgetMonthPrivacyProjection.displayMonth(
            month,
            isEnabled: privacyEnabled,
            currency: currency
        ) ?? month
        let projectedCategories = Dictionary(
            uniqueKeysWithValues: displayMonth.categoryGroups.flatMap(\.categories).map { ($0.id, $0) }
        )

        var categories: [WidgetCategorySnapshot] = []
        for group in month.categoryGroups where !group.isIncome {
            let displayGroupName = privacyEnabled
                ? PrivacyDisplay.name(for: .categoryGroup, seed: group.id)
                : group.name
            for category in group.categories where !category.isIncome {
                let projected = projectedCategories[category.id] ?? category
                let available = projected.balance
                let spent = -projected.spent
                let total = spent + available
                let displayName = privacyEnabled
                    ? PrivacyDisplay.name(for: .category, seed: category.id)
                    : category.name
                categories.append(
                    WidgetCategorySnapshot(
                        id: category.id,
                        displayName: displayName,
                        group: displayGroupName,
                        isHidden: BudgetCategoryVisibility.isEffectivelyHidden(
                            category: category,
                            group: group
                        ),
                        availableMinorUnits: available,
                        formattedAvailable: currency.formatted(available),
                        spending: WidgetCategorySpending(
                            spent: WidgetMoney(minorUnits: spent, formatted: currency.formatted(spent)),
                            total: WidgetMoney(minorUnits: total, formatted: currency.formatted(total))
                        )
                    )
                )
            }
        }

        return WidgetSnapshot(
            schemaVersion: WidgetSnapshot.currentSchemaVersion,
            budgetID: budgetID,
            budgetName: privacyEnabled
                ? PrivacyDisplay.name(for: .budget, seed: budgetID)
                : budgetName,
            month: month.month,
            privacyEnabled: privacyEnabled,
            updatedAt: now,
            categories: categories
        )
    }
}
