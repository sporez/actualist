import Foundation

enum ScheduleUpcomingLength {
    static func days(
        for value: String,
        today: String,
        calendar: Calendar = .actualScheduleGregorian
    ) -> Int {
        guard let todayDate = ActualScheduleRecurrence.date(from: today, calendar: calendar) else { return 7 }
        switch value {
        case "currentMonth":
            guard let range = calendar.range(of: .day, in: .month, for: todayDate) else { return 7 }
            return max(range.count - calendar.component(.day, from: todayDate), 0)
        case "oneMonth":
            guard let monthStart = calendar.dateInterval(of: .month, for: todayDate)?.start,
                  let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
                  let days = calendar.dateComponents([.day], from: monthStart, to: nextMonth).day else { return 7 }
            return days
        default:
            let components = value.split(separator: "-", maxSplits: 1).map(String.init)
            if components.count == 2, let count = Int(components[0]) {
                let safeCount = max(count, 1)
                switch components[1] {
                case "day": return safeCount
                case "week":
                    let days = safeCount.multipliedReportingOverflow(by: 7)
                    return days.overflow ? 7 : days.partialValue
                case "month", "year":
                    let months: Int
                    if components[1] == "year" {
                        let result = safeCount.multipliedReportingOverflow(by: 12)
                        guard !result.overflow else { return 7 }
                        months = result.partialValue
                    } else {
                        months = safeCount
                    }
                    guard let monthStart = calendar.dateInterval(of: .month, for: todayDate)?.start,
                          let future = calendar.date(byAdding: .month, value: months, to: todayDate),
                          let days = calendar.dateComponents([.day], from: monthStart, to: future).day else { return 7 }
                    let inclusiveDays = days.addingReportingOverflow(1)
                    return inclusiveDays.overflow ? 7 : inclusiveDays.partialValue
                default: return 7
                }
            }
            return Int(value) ?? 7
        }
    }
}
