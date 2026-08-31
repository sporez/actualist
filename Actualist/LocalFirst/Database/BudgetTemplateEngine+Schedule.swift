import Foundation

extension BudgetTemplateEngine {
    struct ResolvedSchedule: Equatable, Sendable {
        let name: String
        let amount: Int
        let nextDate: String
        let monthsUntil: Int
        let interval: Int
        let frequency: String?
        let completed: Bool
        let full: Bool
        let isRepeating: Bool
        let recurrence: BudgetTemplateScheduleRecurrence?
        let monthlyRepeatingTarget: Int
    }

    func computeScheduleAmount(
        _ entries: [BudgetTemplateEntry],
        monthValue: Int,
        category: Category,
        alreadyBudgeted: Int
    ) throws -> Int {
        let instances = try scheduleInstances(
            entries,
            monthValue: monthValue,
            category: category
        )
        let payMonthOf = instances.filter { isPayMonthOf($0) }
        let sinking = instances.filter { !isPayMonthOf($0) }
            .sorted { $0.nextDate < $1.nextDate }

        let totalPayMonthOf = payMonthOf.reduce(0) { $0 + $1.monthlyRepeatingTarget }
        let totalSinking = sinking.reduce(0) { $0 + $1.monthlyRepeatingTarget }
        let totalSinkingBase = sinking.reduce(0.0) { $0 + monthlyBaseContribution($1) }
        let balance = try Self.checkedAdd(category.fromLastMonth, alreadyBudgeted)
        let lastMonthGoal = category.lastMonthGoal
        let subMonthlyCount = instances.filter(isSubMonthly).count

        if balance >= totalSinking + totalPayMonthOf
            || lastMonthGoal < totalSinking + totalPayMonthOf
            && lastMonthGoal != 0
            && balance >= lastMonthGoal
            && subMonthlyCount > 0 {
            return try Self.actualRound(Double(totalPayMonthOf) + totalSinkingBase)
        }

        let sinkingContribution = sinkingContributionTotal(
            sinking,
            lastMonthBalance: category.fromLastMonth
        )
        if sinking.isEmpty {
            return try Self.checkedSubtract(
                try Self.actualRound(Double(totalPayMonthOf) + sinkingContribution),
                category.fromLastMonth
            )
        }
        return try Self.actualRound(Double(totalPayMonthOf) + sinkingContribution)
    }

    private func scheduleInstances(
        _ entries: [BudgetTemplateEntry],
        monthValue: Int,
        category: Category
    ) throws -> [ResolvedSchedule] {
        var instances: [ResolvedSchedule] = []
        for entry in entries where entry.type == "schedule" {
            guard let key = entry.scheduleLookupKey,
                  let resolved = category.resolvedSchedules[key] else {
                throw LocalFirstError.unsupportedTemplate(entry.missingScheduleReason)
            }
            if resolved.completed || resolved.monthsUntil < 0 {
                continue
            }
            var instance = resolved
            if instance.isRepeating, !instance.completed {
                instance = try withMonthlyRepeatingTarget(instance, monthValue: monthValue)
            }
            instances.append(instance)
        }
        return instances
    }

    private func withMonthlyRepeatingTarget(
        _ schedule: ResolvedSchedule,
        monthValue: Int
    ) throws -> ResolvedSchedule {
        guard let recurrence = schedule.recurrence else {
            return schedule
        }
        let monthStart = try BudgetTemplateCalendar.monthStartDate(monthValue)
        guard var cursor = try recurrence.nextDate(onOrAfter: monthStart) else {
            return schedule
        }

        func displayDate(for date: Date) throws -> Date {
            recurrence.skipWeekend ? try recurrence.skippedWeekend(date) : date
        }

        // Actual totals repeating occurrences through the month containing the
        // schedule's next occurrence, not merely through the budget month. A
        // future yearly bill therefore keeps one target for sinking-fund math.
        let firstDisplayDate = try displayDate(for: cursor)
        guard let occurrenceMonth = BudgetTemplateCalendar.gregorian.dateInterval(
            of: .month,
            for: firstDisplayDate
        ) else {
            throw LocalFirstError.unsupportedTemplate("schedule recurrence")
        }
        let occurrenceMonthEnd = occurrenceMonth.end
        let sign = schedule.monthlyRepeatingTarget >= 0 ? 1 : -1
        let magnitude = abs(schedule.amount)
        var total = 0
        var guardCount = 0
        while true {
            let display = try displayDate(for: cursor)
            guard display < occurrenceMonthEnd else {
                break
            }
            total = try Self.checkedAdd(total, magnitude)
            guard let next = BudgetTemplateCalendar.gregorian.date(
                byAdding: .day,
                value: 1,
                to: cursor
            ),
                  let advanced = try recurrence.nextDate(onOrAfter: next),
                  BudgetTemplateCalendar.gregorian.startOfDay(for: advanced)
                    != BudgetTemplateCalendar.gregorian.startOfDay(for: cursor) else {
                break
            }
            cursor = advanced
            guardCount += 1
            if guardCount > 400 {
                throw LocalFirstError.unsupportedTemplate("schedule recurrence")
            }
        }
        return ResolvedSchedule(
            name: schedule.name,
            amount: schedule.amount,
            nextDate: schedule.nextDate,
            monthsUntil: schedule.monthsUntil,
            interval: schedule.interval,
            frequency: schedule.frequency,
            completed: schedule.completed,
            full: schedule.full,
            isRepeating: schedule.isRepeating,
            recurrence: schedule.recurrence,
            monthlyRepeatingTarget: sign * total
        )
    }

    private func isPayMonthOf(_ schedule: ResolvedSchedule) -> Bool {
        if schedule.full {
            return true
        }
        let frequency = schedule.frequency
        if (frequency == "monthly" || frequency == nil)
            && schedule.interval == 1
            && schedule.monthsUntil == 0 {
            return true
        }
        if frequency == "weekly", schedule.interval <= 4 {
            return true
        }
        if frequency == "daily", schedule.interval <= 31 {
            return true
        }
        return false
    }

    private func isSubMonthly(_ schedule: ResolvedSchedule) -> Bool {
        schedule.frequency == "weekly" || schedule.frequency == "daily"
    }

    private func monthlyBaseContribution(_ schedule: ResolvedSchedule) -> Double {
        let target = Double(schedule.monthlyRepeatingTarget)
        let interval = Double(max(schedule.interval, 1))
        switch schedule.frequency {
        case "yearly":
            return target / interval / 12
        case "monthly":
            return target / interval
        case "weekly":
            return target / Double(max(weeklyIntervalMonths(schedule), 1))
        case "daily":
            return target / Double(max(dailyIntervalMonths(schedule), 1))
        default:
            return target / interval
        }
    }

    private func weeklyIntervalMonths(_ schedule: ResolvedSchedule) -> Int {
        guard let date = BudgetTemplateCalendar.validatedDate(schedule.nextDate),
              let previous = BudgetTemplateCalendar.gregorian.date(
                byAdding: .day,
                value: -schedule.interval * 7,
                to: date
              ) else {
            return 1
        }
        let months = BudgetTemplateCalendar.gregorian.dateComponents(
            [.month],
            from: previous,
            to: date
        ).month ?? 0
        return months == 0 ? 1 : months
    }

    private func dailyIntervalMonths(_ schedule: ResolvedSchedule) -> Int {
        guard let date = BudgetTemplateCalendar.validatedDate(schedule.nextDate),
              let previous = BudgetTemplateCalendar.gregorian.date(
                byAdding: .day,
                value: -schedule.interval,
                to: date
              ) else {
            return 1
        }
        let months = BudgetTemplateCalendar.gregorian.dateComponents(
            [.month],
            from: previous,
            to: date
        ).month ?? 0
        return months == 0 ? 1 : months
    }

    private func sinkingContributionTotal(
        _ schedules: [ResolvedSchedule],
        lastMonthBalance: Int
    ) -> Double {
        var remainder = 0
        var total = 0.0
        for (index, schedule) in schedules.enumerated() {
            remainder = index == 0
                ? schedule.monthlyRepeatingTarget - lastMonthBalance
                : schedule.monthlyRepeatingTarget - remainder
            if remainder >= 0 {
                total += Double(remainder) / Double(schedule.monthsUntil + 1)
                remainder = 0
            } else {
                remainder = abs(remainder)
            }
        }
        return total
    }
}
