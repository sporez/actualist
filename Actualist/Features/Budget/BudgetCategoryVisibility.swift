import Foundation

/// Budget list and picker projection for Actual's `hidden` flags.
///
/// SQLite still returns every live group and category. Hide is visual:
/// leftover stays in stored group / month totals. Effective hidden is
/// `category.hidden || group.hidden`; hiding a group does not flip child flags.
enum BudgetCategoryVisibility {
    static func isHidden(_ flag: Bool?) -> Bool {
        flag ?? false
    }

    static func isEffectivelyHidden(
        categoryHidden: Bool?,
        groupHidden: Bool?
    ) -> Bool {
        isHidden(categoryHidden) || isHidden(groupHidden)
    }

    static func isEffectivelyHidden(
        category: BudgetMonthCategory,
        group: BudgetMonthCategoryGroup
    ) -> Bool {
        isEffectivelyHidden(categoryHidden: category.hidden, groupHidden: group.hidden)
    }

    static func visibleCategories(in group: BudgetMonthCategoryGroup) -> [BudgetMonthCategory] {
        displayedCategories(in: group, showHidden: false)
    }

    static func displayedCategories(
        in group: BudgetMonthCategoryGroup,
        showHidden: Bool
    ) -> [BudgetMonthCategory] {
        if showHidden {
            return group.categories
        }
        return group.categories.filter { !isEffectivelyHidden(category: $0, group: group) }
    }

    static func displayedGroups(
        from groups: [BudgetMonthCategoryGroup],
        showHidden: Bool
    ) -> [BudgetMonthCategoryGroup] {
        groups.filter { group in
            guard !group.isIncome else {
                return false
            }
            return showHidden || !isHidden(group.hidden)
        }
    }
}
