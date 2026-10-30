import Foundation

enum WidgetMonthID {
    static func current(now: Date = Date(), calendar: Calendar? = nil) -> String {
        let resolvedCalendar = calendar ?? gregorianCalendar()
        let parts = resolvedCalendar.dateComponents([.year, .month], from: now)
        guard let year = parts.year, let month = parts.month else {
            return ""
        }
        return String(format: "%04d-%02d", year, month)
    }

    static func nextBoundary(after date: Date, graceInterval: TimeInterval = 60) -> Date {
        gregorianCalendar().dateInterval(of: .month, for: date)?.end
            .addingTimeInterval(graceInterval) ?? date.addingTimeInterval(6 * 60 * 60)
    }

    /// Each midnight left in the month of `date`, for timelines that show the day.
    static func dailyBoundaries(after date: Date, calendar: Calendar? = nil) -> [Date] {
        let resolvedCalendar = calendar ?? gregorianCalendar()
        guard let end = resolvedCalendar.dateInterval(of: .month, for: date)?.end else { return [] }
        var boundaries: [Date] = []
        var cursor = date
        while let next = resolvedCalendar.nextDate(
            after: cursor, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime
        ), next < end {
            boundaries.append(next)
            cursor = next
        }
        return boundaries
    }

    /// The month's name in the user's language, or nil for a non-canonical ID.
    static func displayName(_ value: String, calendar: Calendar? = nil) -> String? {
        guard isCanonical(value), let month = Int(value.suffix(2)) else { return nil }
        return (calendar ?? gregorianCalendar()).standaloneMonthSymbols[month - 1]
    }

    static func isCanonical(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == 4,
              parts[1].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]) else {
            return false
        }
        return (1900...9999).contains(year) && (1...12).contains(month)
    }

    private static func gregorianCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        calendar.locale = .autoupdatingCurrent
        return calendar
    }
}
