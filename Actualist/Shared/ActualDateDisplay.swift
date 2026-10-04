import Foundation

/// Display text for Actual day (`yyyy-MM-dd`) and month (`yyyy-MM`) ids.
///
/// Day and month ids are Gregorian calendar facts, independent of the device's
/// calendar and time zone. Every format here pins a Gregorian calendar and UTC
/// explicitly: `Date.FormatStyle` uses the locale's calendar otherwise (a
/// Persian, Buddhist, Islamic or Hebrew locale would relabel the same day), and
/// a date built at local midnight prints as the previous day east of UTC.
/// Formats are immutable value styles, so there is no shared formatter state.
enum ActualDateDisplay {
    enum MonthWidth: Sendable {
        case abbreviated
        case wide
    }

    /// `March 5, 2026`.
    static func longDay(_ dayID: String, locale: Locale = .current) -> String? {
        guard let date = ActualScheduleRecurrence.date(from: dayID) else { return nil }
        return date.formatted(style(locale).year().month(.wide).day())
    }

    /// `Thursday, March 5, 2026`.
    static func weekdayLongDay(_ dayID: String, locale: Locale = .current) -> String? {
        guard let date = ActualScheduleRecurrence.date(from: dayID) else { return nil }
        return date.formatted(style(locale).weekday(.wide).year().month(.wide).day())
    }

    /// The locale's medium date (`Mar 5, 2026`) for a day id.
    static func mediumDay(_ dayID: String, locale: Locale = .current) -> String? {
        guard let date = ActualDateOnly.date(from: dayID, timeZone: ActualDateOnly.utc) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = ActualDateOnly.utc
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// `March` for a month id.
    static func monthName(_ monthID: String, locale: Locale = .current) -> String? {
        guard let date = monthStart(monthID) else { return nil }
        return date.formatted(style(locale).month(.wide))
    }

    /// `Mar 2026` or `March 2026` for a month id.
    static func monthYear(_ monthID: String, width: MonthWidth = .abbreviated, locale: Locale = .current) -> String? {
        guard let date = monthStart(monthID) else { return nil }
        let format = style(locale).year()
        return date.formatted(width == .wide ? format.month(.wide) : format.month(.abbreviated))
    }

    private static func monthStart(_ monthID: String) -> Date? {
        let parts = monthID.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
        return ActualScheduleRecurrence.date(from: YearMonth.id(year: year, month: month) + "-01")
    }

    private static func style(_ locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: .actualScheduleGregorian, timeZone: .gmt)
    }
}
