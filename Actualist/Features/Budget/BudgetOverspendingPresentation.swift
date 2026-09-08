import Foundation

/// The alert count and its review list must select the same displayed deficits.
/// Cover workflows pass real months; sample-value reviews pass projected months.
enum BudgetOverspendingPresentation {
    static func options(
        in month: BudgetMonth?,
        isTrackingBudget: Bool,
        includeCarryover: Bool
    ) -> [BudgetOverspentCategoryOption] {
        (month?.categoryGroups ?? []).filter { !$0.isIncome }.flatMap { group in
            BudgetCategoryVisibility.overspentCategories(in: group, isTrackingBudget: isTrackingBudget)
                .compactMap { category in
                    guard category.balance < 0, includeCarryover || !category.carryover else { return nil }
                    return BudgetOverspentCategoryOption(id: category.id, groupName: group.name, category: category)
                }
        }
    }
}
