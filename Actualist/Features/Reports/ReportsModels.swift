import Foundation

struct ReportDateRange: Hashable, Sendable {
    let anchorMonth: String
    let startDay: String
    let endDay: String

    static func dashboard(through date: Date, calendar: Calendar = ReportCalendar.gregorianLocal) -> Self {
        let startOfDay = calendar.startOfDay(for: date)
        let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: startOfDay)
        ) ?? startOfDay
        let rangeStart = calendar.date(byAdding: .month, value: -5, to: monthStart) ?? monthStart
        return Self(
            anchorMonth: ReportCalendar.monthID(for: startOfDay, calendar: calendar),
            startDay: ReportCalendar.dayID(for: rangeStart, calendar: calendar),
            endDay: ReportCalendar.dayID(for: startOfDay, calendar: calendar)
        )
    }

    var cacheKey: String {
        "\(anchorMonth)|\(startDay)|\(endDay)"
    }
}

struct ReportValuePoint: Identifiable, Hashable, Sendable {
    let dayID: String
    let value: Int

    var id: String { dayID }
    var date: Date { ReportCalendar.date(fromDayID: dayID) ?? .distantPast }
}

struct DailyComparisonPoint: Identifiable, Hashable, Sendable {
    let day: Int
    let current: Int?
    let comparison: Int

    var id: Int { day }
}

struct NetWorthReport: Equatable, Sendable {
    let points: [ReportValuePoint]
    let balance: Int
    let change: Int
}

struct CashFlowSummary: Equatable, Sendable {
    let month: String
    let income: Int
    let expenses: Int
    let net: Int
    let uncategorized: Int
}

struct MonthComparisonReport: Equatable, Sendable {
    let currentMonth: String
    let comparisonMonth: String
    let points: [DailyComparisonPoint]
    let variance: Int
}

struct BudgetOverviewReport: Equatable, Sendable {
    let month: String
    let actualPoints: [ReportValuePoint]
    let budgetPoints: [ReportValuePoint]
    let actualExpenses: Int
    let budgetedExpenses: Int
    let variance: Int
}

struct ThreeMonthAverageReport: Equatable, Sendable {
    let month: String
    let points: [DailyComparisonPoint]
    let currentExpenses: Int
    let averageExpenses: Int
    let variance: Int
}

struct TransactionCalendarDay: Identifiable, Hashable, Sendable {
    let dayID: String
    let day: Int
    let income: Int
    let expenses: Int

    var id: String { dayID }
    var date: Date { ReportCalendar.date(fromDayID: dayID) ?? .distantPast }
}

struct TransactionCalendarMonth: Identifiable, Equatable, Sendable {
    let month: String
    let leadingBlankCount: Int
    let days: [TransactionCalendarDay]
    let income: Int
    let expenses: Int

    var id: String { month }
}

struct ReportsDashboardSnapshot: Equatable, Sendable {
    let range: ReportDateRange
    let hasData: Bool
    let netWorth: NetWorthReport
    let cashFlow: CashFlowSummary
    let monthComparison: MonthComparisonReport
    let budgetOverview: BudgetOverviewReport
    let threeMonthAverage: ThreeMonthAverageReport
    let transactionCalendar: [TransactionCalendarMonth]
}

struct ReportDailyActivity: Equatable, Sendable {
    var income = 0
    var expenses = 0
    var uncategorized = 0

    var net: Int { income - expenses }
}

enum ReportCalendar {
    static var gregorianLocal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static var gregorianUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    static func date(fromDayID dayID: String, calendar: Calendar = gregorianUTC) -> Date? {
        let parts = dayID.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    static func date(fromMonthID monthID: String, calendar: Calendar = gregorianUTC) -> Date? {
        let parts = monthID.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]) else {
            return nil
        }
        return calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }

    static func dayID(for date: Date, calendar: Calendar = gregorianUTC) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func monthID(for date: Date, calendar: Calendar = gregorianUTC) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    static func shiftedMonth(_ monthID: String, by offset: Int, calendar: Calendar = gregorianUTC) -> String {
        guard let date = date(fromMonthID: monthID, calendar: calendar),
              let shifted = calendar.date(byAdding: .month, value: offset, to: date) else {
            return monthID
        }
        return self.monthID(for: shifted, calendar: calendar)
    }

    static func days(in monthID: String, calendar: Calendar = gregorianUTC) -> Int {
        guard let date = date(fromMonthID: monthID, calendar: calendar),
              let range = calendar.range(of: .day, in: .month, for: date) else {
            return 0
        }
        return range.count
    }

    static func dayID(month: String, day: Int) -> String {
        String(format: "%@-%02d", month, day)
    }

    static func dayNumber(from dayID: String) -> Int {
        Int(dayID.suffix(2)) ?? 0
    }

    static func dayIDs(from startDay: String, through endDay: String, calendar: Calendar = gregorianUTC) -> [String] {
        guard let start = date(fromDayID: startDay, calendar: calendar),
              let end = date(fromDayID: endDay, calendar: calendar),
              start <= end else {
            return []
        }

        var result: [String] = []
        var cursor = start
        while cursor <= end {
            result.append(dayID(for: cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = next
        }
        return result
    }

    static func monthTitle(_ monthID: String) -> String {
        guard let date = date(fromMonthID: monthID) else { return monthID }
        return formatter("MMMM yyyy").string(from: date)
    }

    static func shortMonthTitle(_ monthID: String) -> String {
        guard let date = date(fromMonthID: monthID) else { return monthID }
        return formatter("MMM yyyy").string(from: date)
    }

    static func rangeTitle(startDay: String, endDay: String) -> String {
        guard let start = date(fromDayID: startDay), let end = date(fromDayID: endDay) else {
            return "\(startDay) – \(endDay)"
        }
        let formatter = formatter("MMM yyyy")
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    static func longDayTitle(_ dayID: String) -> String {
        guard let date = date(fromDayID: dayID) else { return dayID }
        return formatter("EEEE, MMMM d, yyyy").string(from: date)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = gregorianUTC
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = .current
        formatter.dateFormat = format
        return formatter
    }
}
