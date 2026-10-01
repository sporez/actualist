import Foundation

/// Converts between Actual's `yyyy-MM-dd` calendar-day values and `Date`
/// without treating a date-only value as an instant at GMT midnight.
enum ActualDateOnly {
    static let utc = TimeZone.gmt

    static func dayID(from date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return ActualScheduleRecurrence.dayID(from: date, calendar: calendar)
    }

    static func date(from dayID: String, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return ActualScheduleRecurrence.date(from: dayID, calendar: calendar)
    }

    /// Returns calendar-day distance, independent of UTC offset and DST length.
    static func dayDistance(from firstDayID: String, to secondDayID: String) -> Int? {
        let calendar = Calendar.actualScheduleGregorian
        guard let first = ActualScheduleRecurrence.date(from: firstDayID, calendar: calendar),
              let second = ActualScheduleRecurrence.date(from: secondDayID, calendar: calendar),
              let distance = calendar.dateComponents([.day], from: first, to: second).day else {
            return nil
        }
        return distance
    }

    static func dayDistance(fromCompact firstDayID: String, toCompact secondDayID: String) -> Int? {
        guard let first = dashedDayID(fromCompact: firstDayID),
              let second = dashedDayID(fromCompact: secondDayID) else { return nil }
        return dayDistance(from: first, to: second)
    }

    private static func dashedDayID(fromCompact dayID: String) -> String? {
        let digits = Array(dayID)
        guard digits.count == 8, digits.allSatisfy(\.isNumber) else { return nil }
        return "\(dayID.prefix(4))-\(dayID.dropFirst(4).prefix(2))-\(dayID.suffix(2))"
    }
}
