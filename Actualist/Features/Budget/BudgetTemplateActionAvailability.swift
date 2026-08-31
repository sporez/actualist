enum BudgetTemplateActionAvailability {
    static func hasMonthActions(
        in month: BudgetMonth?,
        isTrackingBudget: Bool
    ) -> Bool {
        guard let month else {
            return false
        }
        return month.categoryGroups.contains { group in
            guard !(group.hidden ?? false), isTrackingBudget || !group.isIncome else {
                return false
            }
            return group.categories.contains { category in
                !(category.hidden ?? false) && category.hasTemplateDefinition
            }
        }
    }

    static func hasCategoryAction(
        for categoryID: String?,
        in groups: [BudgetMonthCategoryGroup]
    ) -> Bool {
        guard let categoryID else {
            return false
        }
        return groups
            .flatMap(\.categories)
            .first { $0.id == categoryID }?
            .hasTemplateDefinition == true
    }
}
