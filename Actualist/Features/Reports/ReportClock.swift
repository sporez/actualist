import Foundation

/// The date Reports treats as today.
///
/// DEBUG builds accept `-actualist-report-today yyyy-MM-dd` so UI tests on the
/// bundled demo budget (whose data ends 2026-08-31) keep the preset ranges
/// ("Last 3 Months", "This Month") over real data after the run date moves on.
/// Release builds always return the current date. Only Reports reads this clock.
enum ReportClock {
    static var now: Date {
        #if DEBUG
        pinned ?? Date()
        #else
        Date()
        #endif
    }

    #if DEBUG
    private static let pinned = pinnedDate(from: ProcessInfo.processInfo.arguments)

    static func pinnedDate(from arguments: [String]) -> Date? {
        guard let flag = arguments.firstIndex(of: "-actualist-report-today"),
              arguments.indices.contains(flag + 1),
              let noon = ReportCalendar.date(fromDayID: arguments[flag + 1]) else { return nil }
        // Noon UTC keeps the same calendar day in every local time zone.
        return noon.addingTimeInterval(12 * 3600)
    }
    #endif
}
