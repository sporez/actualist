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
        let projectedBalances = Dictionary(
            uniqueKeysWithValues: displayMonth.categoryGroups.flatMap(\.categories).map {
                ($0.id, $0.balance)
            }
        )

        var categories: [WidgetCategorySnapshot] = []
        for group in month.categoryGroups where !group.isIncome {
            let displayGroupName = privacyEnabled
                ? PrivacyDisplay.name(for: .categoryGroup, seed: group.id)
                : group.name
            for category in group.categories where !category.isIncome {
                let available = projectedBalances[category.id] ?? category.balance
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
                        formattedAvailable: currency.formatted(available)
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
