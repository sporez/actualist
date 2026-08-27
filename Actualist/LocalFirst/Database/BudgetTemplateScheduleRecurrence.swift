import Foundation

struct BudgetTemplateScheduleRecurrence: Equatable, Sendable {
    let start: Date
    let frequency: String
    let interval: Int
    let skipWeekend: Bool
    let weekendSolveMode: String

    func nextDateString(onOrAfter startDate: Date, applyWeekendSkip: Bool) throws -> String? {
        guard let date = try nextDate(onOrAfter: startDate) else {
            return nil
        }
        if applyWeekendSkip, skipWeekend {
            return BudgetTemplateCalendar.dayID(from: try skippedWeekend(date))
        }
        return BudgetTemplateCalendar.dayID(from: date)
    }

    func nextDate(onOrAfter startDate: Date) throws -> Date? {
        let calendar = BudgetTemplateCalendar.gregorian
        let startDay = calendar.startOfDay(for: start)
        let searchDay = calendar.startOfDay(for: startDate)
        if startDay >= searchDay {
            return start
        }

        switch frequency {
        case "daily":
            guard let days = calendar.dateComponents([.day], from: startDay, to: searchDay).day else {
                return nil
            }
            let steps = (days + interval - 1) / interval
            return calendar.date(byAdding: .day, value: steps * interval, to: start)
        case "weekly":
            guard let days = calendar.dateComponents([.day], from: startDay, to: searchDay).day else {
                return nil
            }
            let stepDays = interval * 7
            let steps = (days + stepDays - 1) / stepDays
            return calendar.date(byAdding: .day, value: steps * stepDays, to: start)
        case "monthly":
            guard let months = calendar.dateComponents([.month], from: startDay, to: searchDay).month else {
                return nil
            }
            var steps = (months + interval - 1) / interval
            var candidate = calendar.date(byAdding: .month, value: steps * interval, to: start)
            while let date = candidate, calendar.startOfDay(for: date) < searchDay {
                steps += 1
                candidate = calendar.date(byAdding: .month, value: steps * interval, to: start)
            }
            return candidate
        case "yearly":
            guard let years = calendar.dateComponents([.year], from: startDay, to: searchDay).year else {
                return nil
            }
            var steps = (years + interval - 1) / interval
            var candidate = calendar.date(byAdding: .year, value: steps * interval, to: start)
            while let date = candidate, calendar.startOfDay(for: date) < searchDay {
                steps += 1
                candidate = calendar.date(byAdding: .year, value: steps * interval, to: start)
            }
            return candidate
        default:
            throw LocalFirstError.unsupportedTemplate(
                "unsupported schedule frequency"
            )
        }
    }

    func skippedWeekend(_ date: Date) throws -> Date {
        let weekday = BudgetTemplateCalendar.gregorian.component(.weekday, from: date)
        let isWeekend = weekday == 1 || weekday == 7
        guard isWeekend else {
            return date
        }
        switch weekendSolveMode {
        case "after":
            let days = weekday == 7 ? 2 : 1
            guard let next = BudgetTemplateCalendar.gregorian.date(
                byAdding: .day,
                value: days,
                to: date
            ) else {
                throw LocalFirstError.unsupportedTemplate("schedule weekend")
            }
            return next
        case "before":
            let days = weekday == 7 ? -1 : -2
            guard let previous = BudgetTemplateCalendar.gregorian.date(
                byAdding: .day,
                value: days,
                to: date
            ) else {
                throw LocalFirstError.unsupportedTemplate("schedule weekend")
            }
            return previous
        default:
            throw LocalFirstError.unsupportedTemplate("Unknown weekend solve mode, this should not happen!")
        }
    }
}
