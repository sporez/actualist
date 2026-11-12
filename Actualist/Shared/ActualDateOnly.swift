import Foundation

/// Converts between Actual's `yyyy-MM-dd` calendar-day values and `Date`
/// without treating a date-only value as an instant at GMT midnight.
enum ActualDateOnly {
    static let utc = TimeZone.gmt

    /// The Gregorian POSIX-locale calendar every day-ID conversion uses.
    static func calendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }

    static func dayID(from date: Date, timeZone: TimeZone) -> String {
        ActualScheduleRecurrence.dayID(from: date, calendar: calendar(timeZone: timeZone))
    }

    /// The calendar day `now` falls on in `timeZone` (the device zone by
    /// default), not the UTC day.
    static func today(now: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> String {
        dayID(from: now, timeZone: timeZone)
    }

    static func date(from dayID: String, timeZone: TimeZone) -> Date? {
        ActualScheduleRecurrence.date(from: dayID, calendar: calendar(timeZone: timeZone))
    }

    /// Lenient variant of `date(from:timeZone:)`: any digit count, and a day or
    /// month out of range rolls forward ("2026-02-31" is 2026-03-03). Reports,
    /// the schedule editor and the transaction filter rely on that, so it
    /// stays a named variant instead of being tightened. `hour` nil builds
    /// midnight (Reports, filter); a value builds that hour (editors use noon).
    /// `ignoringNonNumericParts` drops non-numeric `-` pieces before counting
    /// three, as the schedule editor and filter always did; Reports needs
    /// exactly three numeric pieces.
    static func lenientDate(
        fromDayID dayID: String,
        calendar: Calendar = .actualScheduleGregorian,
        hour: Int? = nil,
        ignoringNonNumericParts: Bool = false
    ) -> Date? {
        let pieces = dayID.split(separator: "-")
        let numbers = pieces.compactMap { Int($0) }
        guard numbers.count == 3, ignoringNonNumericParts || pieces.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: numbers[0], month: numbers[1], day: numbers[2], hour: hour))
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

    /// Whole days since 1970-01-01 for a `yyyy-MM-dd` ID, or nil when it does
    /// not parse. The calendar is fixed to GMT, so differences of epoch days
    /// equal `dayDistance(from:to:)`.
    static func epochDay(_ dayID: String) -> Int? {
        guard let date = ActualScheduleRecurrence.date(from: dayID, calendar: Calendar.actualScheduleGregorian) else {
            return nil
        }
        return Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
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
