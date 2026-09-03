import Foundation

/// Calendar-only editor behavior for periodic starts and weekly limits.
/// Dates are kept as Actual day ids and are never converted through UTC.
enum BudgetTemplateEditorCalendar {
    static func defaultWeeklyStart(
        for drafts: [BudgetTemplateDraft],
        now: Date
    ) -> String {
        let candidates = drafts.compactMap { draft -> String? in
            switch draft {
            case .monthlyFixed(let value):
                return BudgetTemplateCalendar.validatedDate(value.starting) == nil
                    ? nil
                    : value.starting
            case .dateTarget(let value):
                guard BudgetTemplateCalendar.validMonth(value.month) else { return nil }
                return "\(value.month)-01"
            default:
                return nil
            }
        }
        return candidates.min() ?? BudgetTemplateDefinition.firstDayOfCurrentMonth(now: now)
    }

    static func weekday(for dayID: String) -> Int? {
        guard let date = BudgetTemplateCalendar.validatedDate(dayID) else { return nil }
        return BudgetTemplateCalendar.gregorian.component(.weekday, from: date)
    }

    static func dayID(_ dayID: String, movingToWeekday targetWeekday: Int) -> String? {
        guard (1...7).contains(targetWeekday),
              let date = BudgetTemplateCalendar.validatedDate(dayID),
              let currentWeekday = weekday(for: dayID),
              let shifted = BudgetTemplateCalendar.gregorian.date(
                  byAdding: .day,
                  value: targetWeekday - currentWeekday,
                  to: date
              ) else {
            return nil
        }
        return BudgetTemplateCalendar.dayID(from: shifted)
    }

    static func weekdayName(_ weekday: Int) -> String {
        guard (1...7).contains(weekday) else { return "" }
        return BudgetTemplateCalendar.gregorian.weekdaySymbols[weekday - 1]
    }
}
