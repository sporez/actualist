import Foundation

/// Display-only sample-values projection for the Budget screen.
///
/// Randomizes category leaf amounts, then recomputes available, group totals,
/// and month totals with the same identities `BudgetDatabase.fetchBudgetMonth`
/// uses. The real `BudgetMonth` stays the source of truth for writes.
enum BudgetMonthPrivacyProjection {
    static func displayMonth(
        _ month: BudgetMonth?,
        isEnabled: Bool,
        currency: BudgetCurrency = .usd
    ) -> BudgetMonth? {
        guard let month else {
            return nil
        }
        guard isEnabled else {
            return month
        }
        return project(month, currency: currency)
    }

    static func project(_ month: BudgetMonth, currency: BudgetCurrency = .usd) -> BudgetMonth {
        let groups = month.categoryGroups.map {
            project(group: $0, month: month.month, currency: currency)
        }
        let expenseGroups = groups.filter { !$0.isIncome }
        let incomeGroups = groups.filter(\.isIncome)
        let totalBudgeted = expenseGroups.reduce(0) { $0 + $1.budgeted }
        let totalSpent = expenseGroups.reduce(0) { $0 + $1.spent }
        let totalBalance = expenseGroups.reduce(0) { $0 + $1.balance }
        let totalIncome = incomeGroups.reduce(0) { $0 + $1.spent }
        let toBudget = leafAmount(
            sign: toBudgetSign(month: month.month),
            seed: "budget-leaf-to-budget-\(month.month)",
            currency: currency,
            maximumDollars: 2_000
        )

        return BudgetMonth(
            month: month.month,
            incomeAvailable: toBudget,
            lastMonthOverspent: month.lastMonthOverspent,
            forNextMonth: month.forNextMonth,
            totalBudgeted: totalBudgeted,
            toBudget: toBudget,
            fromLastMonth: month.fromLastMonth,
            totalIncome: totalIncome,
            totalSpent: totalSpent,
            totalBalance: totalBalance,
            categoryGroups: groups
        )
    }

    private static func project(
        group: BudgetMonthCategoryGroup,
        month: String,
        currency: BudgetCurrency
    ) -> BudgetMonthCategoryGroup {
        let categories = group.categories.map {
            project(category: $0, month: month, currency: currency)
        }
        return BudgetMonthCategoryGroup(
            id: group.id,
            name: group.name,
            isIncome: group.isIncome,
            hidden: group.hidden,
            budgeted: categories.reduce(0) { $0 + $1.budgeted },
            spent: categories.reduce(0) { $0 + $1.spent },
            balance: categories.reduce(0) { $0 + $1.balance },
            categories: categories
        )
    }

    private static func project(
        category: BudgetMonthCategory,
        month: String,
        currency: BudgetCurrency
    ) -> BudgetMonthCategory {
        let budgeted = category.isIncome
            ? 0
            : leafAmount(
                sign: 1,
                seed: "budget-leaf-budgeted-\(month)-\(category.id)",
                currency: currency,
                maximumDollars: 900
            )
        let spent = leafAmount(
            sign: category.isIncome ? 1 : -1,
            seed: "budget-leaf-spent-\(month)-\(category.id)",
            currency: currency,
            maximumDollars: 600
        )
        let leftover = leafAmount(
            sign: leftoverSign(month: month, categoryID: category.id),
            seed: "budget-leaf-leftover-\(month)-\(category.id)",
            currency: currency,
            maximumDollars: 400
        )

        return BudgetMonthCategory(
            id: category.id,
            name: category.name,
            isIncome: category.isIncome,
            hidden: category.hidden,
            groupID: category.groupID,
            budgeted: budgeted,
            spent: spent,
            balance: budgeted + spent + leftover,
            carryover: category.carryover
        )
    }

    private static func leafAmount(
        sign: Int,
        seed: String,
        currency: BudgetCurrency,
        maximumDollars: Int
    ) -> Int {
        PrivacyDisplay.amount(
            sign,
            seed: seed,
            currency: currency,
            minimumDollars: 4,
            maximumDollars: maximumDollars
        )
    }

    private static func leftoverSign(month: String, categoryID: String) -> Int {
        PrivacyDisplay.stableHash("budget-leaf-leftover-sign-\(month)-\(categoryID)") % 2 == 0
            ? 1
            : -1
    }

    private static func toBudgetSign(month: String) -> Int {
        PrivacyDisplay.stableHash("budget-leaf-to-budget-sign-\(month)") % 5 == 0
            ? -1
            : 1
    }
}
