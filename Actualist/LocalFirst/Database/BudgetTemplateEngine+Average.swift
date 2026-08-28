import Foundation

extension BudgetTemplateEngine {
    func computeAverageAmount(
        _ entry: BudgetTemplateEntry,
        monthValue: Int,
        currentMonthValue: Int,
        category: Category
    ) throws -> Int {
        guard let numMonths = entry.numMonths, Bounds.numMonths.contains(numMonths) else {
            throw LocalFirstError.unsupportedTemplate("average")
        }

        let months = try averageHistoryMonths(
            targetMonth: monthValue,
            currentMonth: currentMonthValue,
            maxMonths: numMonths,
            firstRelevantMonth: category.firstRelevantMonth
        )
        guard !months.isEmpty else {
            return 0
        }

        var sum = 0
        for month in months {
            sum = try Self.checkedAdd(sum, category.activityByMonth[month] ?? 0)
        }

        // Actual `getCategoryAverage` rounds the signed mean, then `runAverage`
        // flips only a negative (spending) mean into a budget need.
        var average = Double(try Self.actualRound(Double(sum) / Double(months.count)))
        if average < 0 {
            average *= -1
        }

        if let adjustment = entry.adjustment, let adjustmentType = entry.adjustmentType {
            switch adjustmentType {
            case "percent":
                average = (1 + adjustment / 100) * average
            case "fixed":
                average += Double(try amountToMinorUnits(adjustment))
            default:
                break
            }
        }
        return try Self.actualRound(average)
    }

    func averageHistoryMonths(
        targetMonth: Int,
        currentMonth: Int,
        maxMonths: Int,
        firstRelevantMonth: Int?
    ) throws -> [Int] {
        let startMonth = try averageStartMonth(
            targetMonth: targetMonth,
            currentMonth: currentMonth
        )
        // Actual caps first-activity at the start month. History that only exists
        // after that date is treated as no bound and the full window is used.
        let historyStart: Int?
        if let firstRelevantMonth, firstRelevantMonth <= startMonth {
            historyStart = firstRelevantMonth
        } else {
            historyStart = nil
        }

        var months: [Int] = []
        var cursor = startMonth
        for _ in 0..<maxMonths {
            if let historyStart, cursor < historyStart {
                break
            }
            months.append(cursor)
            cursor = try BudgetTemplateCalendar.shiftedMonth(cursor, by: -1)
        }
        return months
    }

    func averageStartMonth(targetMonth: Int, currentMonth: Int) throws -> Int {
        let previousMonth = try BudgetTemplateCalendar.shiftedMonth(targetMonth, by: -1)
        if previousMonth >= currentMonth {
            return try BudgetTemplateCalendar.shiftedMonth(currentMonth, by: -1)
        }
        return previousMonth
    }
}
