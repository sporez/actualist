import Foundation

extension BudgetTemplateEngine.Category {
    var isGoalOnly: Bool {
        !entries.contains {
            $0.directive == "template" && $0.type != "limit"
        } && entries.contains(where: \.isGoal)
    }
}

extension BudgetTemplateEngine {
    func finalizeWrites(
        categories: [String: Category],
        orderedCategoryIDs: [String],
        budgetedByCategory: [String: Int],
        fullAmountByCategory: [String: Int]
    ) throws -> [Write] {
        try orderedCategoryIDs.compactMap { categoryID in
            guard let category = categories[categoryID] else {
                return nil
            }
            var amount = budgetedByCategory[categoryID] ?? 0
            if let goalEntry = category.entries.first(where: \.isGoal) {
                if category.isGoalOnly {
                    amount = category.previouslyBudgeted
                }
                guard let goalAmount = goalEntry.amount else {
                    throw LocalFirstError.unsupportedTemplate("goal is missing amount")
                }
                return Write(
                    categoryID: categoryID,
                    amount: amount,
                    goal: try amountToMinorUnits(goalAmount),
                    longGoal: 1
                )
            }
            return Write(
                categoryID: categoryID,
                amount: amount,
                goal: fullAmountByCategory[categoryID],
                longGoal: nil
            )
        }
    }
}
