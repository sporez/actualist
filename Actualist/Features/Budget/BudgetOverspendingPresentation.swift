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

/// The last options list and the inputs it was built from, so a render that
/// asks many times builds the list once per distinct month and settings.
struct BudgetOverspendingOptionsMemo {
    private struct Inputs: Equatable {
        var month: BudgetMonth?
        var isTrackingBudget: Bool
        var includeCarryover: Bool
    }

    private var last: (inputs: Inputs, options: [BudgetOverspentCategoryOption])?
    /// Lists actually built, for the work-count test.
    private(set) var buildCount = 0

    mutating func options(
        in month: BudgetMonth?, isTrackingBudget: Bool, includeCarryover: Bool
    ) -> [BudgetOverspentCategoryOption] {
        let inputs = Inputs(month: month, isTrackingBudget: isTrackingBudget, includeCarryover: includeCarryover)
        if let last, last.inputs == inputs { return last.options }
        let options = BudgetOverspendingPresentation.options(
            in: month, isTrackingBudget: isTrackingBudget, includeCarryover: includeCarryover)
        buildCount += 1
        last = (inputs, options)
        return options
    }
}
