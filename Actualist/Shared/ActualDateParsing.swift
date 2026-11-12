import Foundation

extension String {
    /// Parses an Actual `yyyy-MM-dd` date string into noon of that day in the
    /// device zone, as Actual's `parseDate` does (shared/months.ts). Noon
    /// keeps the day through a DST change that skips midnight.
    var actualDate: Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let midnight = formatter.date(from: self) else { return nil }
        return formatter.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: midnight)
    }

    /// Returns the `yyyy-MM` prefix of an Actual date string, or nil if too short.
    var actualYearMonth: String? {
        guard count >= 7 else {
            return nil
        }

        return String(prefix(7))
    }
}
