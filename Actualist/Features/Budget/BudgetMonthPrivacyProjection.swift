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
            project(group: $0, month: month.month, currency: currency, table: month.trackingSummary == nil ? .envelope : .tracking)
        }
        // Samples are bounded to hundreds of display units per leaf; reuse the
        // production aggregate so hidden tracking leaves cannot leak into totals.
        let table: BudgetTable = month.trackingSummary == nil ? .envelope : .tracking
        let totals = try! BudgetFinancialCalculation.totals(groups: groups, table: table)
        let toBudget = table == .tracking ? 0 : leafAmount(
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
            totalBudgeted: totals.budgeted,
            toBudget: toBudget,
            fromLastMonth: month.fromLastMonth,
            totalIncome: totals.income,
            totalSpent: totals.spent,
            totalBalance: totals.balance,
            categoryGroups: groups,
            hasUserNote: month.hasUserNote,
            trackingSummary: totals.tracking
        )
    }

    private static func project(
        group: BudgetMonthCategoryGroup,
        month: String,
        currency: BudgetCurrency,
        table: BudgetTable
    ) -> BudgetMonthCategoryGroup {
        let categories = group.categories.map {
            project(category: $0, month: month, currency: currency, table: table)
        }
        let included = BudgetFinancialCalculation.includedCategories(categories, table: table)
        return BudgetMonthCategoryGroup(
            id: group.id,
            name: group.name,
            isIncome: group.isIncome,
            hidden: group.hidden,
            budgeted: included.reduce(0) { $0 + $1.budgeted },
            spent: included.reduce(0) { $0 + $1.spent },
            balance: included.reduce(0) { $0 + $1.balance },
            categories: categories,
            hasUserNote: group.hasUserNote
        )
    }

    static func project(
        category: BudgetMonthCategory,
        month: String,
        currency: BudgetCurrency,
        table: BudgetTable
    ) -> BudgetMonthCategory {
        let budgeted = category.isIncome && table == .envelope
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

        // The snapshot already includes incoming rollover. Preserve whether it
        // contributed, without inventing a carry balance for a reset month.
        let uncarriedBalance = category.isIncome
            ? category.budgeted - category.spent : category.budgeted + category.spent
        let sampleCarry = table == .tracking && category.balance == uncarriedBalance ? 0 : leftover
        let values = try! BudgetFinancialCalculation.category(
            table: table, isIncome: category.isIncome, budgeted: budgeted,
            activity: spent, carryover: category.carryover,
            previous: BudgetCategoryValue(budgeted: 0, spent: 0, balance: sampleCarry, carryover: true)
        )
        return BudgetMonthCategory(
            id: category.id,
            name: category.name,
            isIncome: category.isIncome,
            hidden: category.hidden,
            groupID: category.groupID,
            budgeted: budgeted,
            spent: spent,
            balance: values.balance,
            carryover: category.carryover,
            hasTemplateDefinition: category.hasTemplateDefinition,
            hasUserNote: category.hasUserNote
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
