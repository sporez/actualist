import Foundation

extension BudgetTemplateEngine {
    func computeSpendAmount(
        _ entry: BudgetTemplateEntry,
        monthValue: Int,
        category: Category
    ) throws -> Int {
        guard let amount = entry.amount,
              let toMonthID = entry.month,
              let fromMonthID = entry.fromMonth,
              var toMonth = try? BudgetTemplateCalendar.parseMonth(toMonthID),
              var fromMonth = try? BudgetTemplateCalendar.parseMonth(fromMonthID) else {
            throw LocalFirstError.unsupportedTemplate("invalid spend template")
        }

        let repeatPeriod: Int?
        if entry.annual == true {
            let years = entry.repeatInterval ?? 1
            let multiplied = years.multipliedReportingOverflow(by: 12)
            guard !multiplied.overflow else {
                throw LocalFirstError.unsupportedTemplate("invalid spend repeat interval")
            }
            repeatPeriod = multiplied.partialValue
        } else {
            repeatPeriod = entry.repeatInterval
        }

        var monthsRemaining = try BudgetTemplateCalendar.monthDistance(
            from: monthValue,
            to: toMonth
        )
        if let repeatPeriod, monthsRemaining < 0 {
            while monthsRemaining < 0 {
                toMonth = try BudgetTemplateCalendar.shiftedMonth(toMonth, by: repeatPeriod)
                fromMonth = try BudgetTemplateCalendar.shiftedMonth(fromMonth, by: repeatPeriod)
                monthsRemaining = try BudgetTemplateCalendar.monthDistance(
                    from: monthValue,
                    to: toMonth
                )
            }
        }
        guard monthsRemaining >= 0 else {
            return 0
        }

        var alreadyBudgeted = category.fromLastMonth
        var cursor = fromMonth
        var isFirstMonth = true
        while try BudgetTemplateCalendar.monthDistance(from: cursor, to: monthValue) > 0 {
            if isFirstMonth {
                let leftover = category.leftoverByMonth[cursor] ?? 0
                let spent = category.spentByMonth[cursor] ?? 0
                alreadyBudgeted = try Self.checkedSubtract(leftover, spent)
                isFirstMonth = false
            } else {
                alreadyBudgeted = try Self.checkedAdd(
                    alreadyBudgeted,
                    category.budgetedByMonth[cursor] ?? 0
                )
            }
            cursor = try BudgetTemplateCalendar.shiftedMonth(cursor, by: 1)
        }

        let target = try amountToMinorUnits(amount)
        return try Self.actualRound(
            Double(try Self.checkedSubtract(target, alreadyBudgeted))
                / Double(try Self.checkedAdd(monthsRemaining, 1))
        )
    }
}
