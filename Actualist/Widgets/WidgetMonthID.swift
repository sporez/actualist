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

    static func nextBoundary(after date: Date) -> Date {
        gregorianCalendar().dateInterval(of: .month, for: date)?.end
            .addingTimeInterval(60) ?? date.addingTimeInterval(6 * 60 * 60)
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
        return calendar
    }
}
