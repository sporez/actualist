import Foundation

enum ReportExplorerMetric: String, Hashable, Sendable {
    case netWorth
    case cashFlow
    case spending
    case budgetOverview
    case spendingAverage

    var title: String {
        switch self {
        case .netWorth: "Net Worth"
        case .cashFlow: "Cash Flow"
        case .spending: "Spending"
        case .budgetOverview: "Budget Overview"
        case .spendingAverage: "Spending Average"
        }
    }
}

enum ReportInterval: String, CaseIterable, Hashable, Sendable {
    case day
    case month

    var title: String {
        switch self {
        case .day: "Daily"
        case .month: "Monthly"
        }
    }
}

enum ReportExplorerRangePreset: String, CaseIterable, Hashable, Sendable {
    case monthToDate
    case threeMonths
    case sixMonths
    case yearToDate
    case custom

    var title: String {
        switch self {
        case .monthToDate: "Month to Date"
        case .threeMonths: "Last 3 Months"
        case .sixMonths: "Last 6 Months"
        case .yearToDate: "Year to Date"
        case .custom: "Custom Range"
        }
    }

    func range(
        through date: Date,
        calendar: Calendar = ReportCalendar.gregorianLocal
    ) -> (startDay: String, endDay: String)? {
        guard self != .custom else { return nil }
        let end = calendar.startOfDay(for: date)
        let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: end)
        ) ?? end
        let start: Date
        switch self {
        case .monthToDate:
            start = monthStart
        case .threeMonths:
            start = calendar.date(byAdding: .month, value: -2, to: monthStart) ?? monthStart
        case .sixMonths:
            start = calendar.date(byAdding: .month, value: -5, to: monthStart) ?? monthStart
        case .yearToDate:
            start = calendar.date(
                from: calendar.dateComponents([.year], from: end)
            ) ?? monthStart
        case .custom:
            return nil
        }
        return (
            ReportCalendar.dayID(for: start, calendar: calendar),
            ReportCalendar.dayID(for: end, calendar: calendar)
        )
    }
}

struct ReportExplorerQuery: Hashable, Sendable {
    let metric: ReportExplorerMetric
    let startDay: String
    let endDay: String
    let interval: ReportInterval

    var hasValidRange: Bool {
        guard ReportCalendar.date(fromDayID: startDay) != nil,
              ReportCalendar.date(fromDayID: endDay) != nil else {
            return false
        }
        return startDay <= endDay
    }

    var rangeTitle: String {
        ReportCalendar.dayRangeTitle(startDay: startDay, endDay: endDay)
    }

    var periods: [ReportExplorerPeriod] {
        guard hasValidRange else { return [] }
        switch interval {
        case .day:
            return ReportCalendar.dayIDs(from: startDay, through: endDay).map {
                ReportExplorerPeriod(startDay: $0, endDay: $0)
            }
        case .month:
            let startMonth = String(startDay.prefix(7))
            let endMonth = String(endDay.prefix(7))
            return ReportCalendar.monthIDs(from: startMonth, through: endMonth).map { month in
                let firstDay = ReportCalendar.dayID(month: month, day: 1)
                let lastDay = ReportCalendar.dayID(
                    month: month,
                    day: max(ReportCalendar.days(in: month), 1)
                )
                return ReportExplorerPeriod(
                    startDay: max(startDay, firstDay),
                    endDay: min(endDay, lastDay)
                )
            }
        }
    }

    var spendingAverageComparison: ReportSpendingAverageComparison? {
        guard metric == .spendingAverage, hasValidRange else { return nil }
        let comparison = ReportExplorerPeriod(startDay: startDay, endDay: endDay)
        let history = (-3 ... -1).map { offset in
            let month = ReportCalendar.shiftedMonth(String(startDay.prefix(7)), by: offset)
            return ReportExplorerPeriod(
                startDay: ReportCalendar.dayID(month: month, day: 1),
                endDay: ReportCalendar.dayID(
                    month: month,
                    day: max(ReportCalendar.days(in: month), 1)
                )
            )
        }
        return ReportSpendingAverageComparison(comparison: comparison, history: history)
    }
}

/// Spending Average compares the selected range with corresponding-day values
/// from the three completed months before its start month.
struct ReportSpendingAverageComparison: Equatable, Sendable {
    let comparison: ReportExplorerPeriod
    let history: [ReportExplorerPeriod]
}

struct ReportExplorerPeriod: Identifiable, Hashable, Sendable {
    let startDay: String
    let endDay: String

    var id: String { "\(startDay)|\(endDay)" }
    var date: Date { ReportCalendar.date(fromDayID: startDay) ?? .distantPast }
}

struct ReportExplorerPoint: Identifiable, Equatable, Sendable {
    let period: ReportExplorerPeriod
    let income: Int
    let expenses: Int
    let net: Int
    let endingBalance: Int
    let budgeted: Int
    let comparison: Int

    var id: String { period.id }
}

struct ReportExplorerTotals: Equatable, Sendable {
    let income: Int
    let expenses: Int
    let net: Int
    let endingBalance: Int
    let balanceChange: Int
    let openingBalance: Int
    let budgeted: Int
    let averageSpending: Int
}

struct ReportExplorerSessionIdentity: Hashable, Sendable {
    let budgetID: String
    let generation: Int
}

struct ReportExplorerSnapshot: Equatable, Sendable {
    let query: ReportExplorerQuery
    let points: [ReportExplorerPoint]
    let totals: ReportExplorerTotals
    let hasData: Bool
}

enum ReportExplorerError: LocalizedError, Equatable {
    case invalidRange

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            "The report start date must be on or before its end date."
        }
    }
}

extension ReportCardKind {
    var explorerMetric: ReportExplorerMetric {
        switch self {
        case .netWorth:
            .netWorth
        case .cashFlow, .transactionCalendar:
            .cashFlow
        case .monthComparison:
            .spending
        case .budgetOverview:
            .budgetOverview
        case .threeMonthAverage:
            .spendingAverage
        }
    }

    var explorerDefaultPreset: ReportExplorerRangePreset {
        switch self {
        case .netWorth:
            .sixMonths
        case .cashFlow, .monthComparison, .budgetOverview, .threeMonthAverage, .transactionCalendar:
            .monthToDate
        }
    }

    var explorerDefaultInterval: ReportInterval {
        switch self {
        case .netWorth, .cashFlow:
            .month
        case .monthComparison, .budgetOverview, .threeMonthAverage, .transactionCalendar:
            .day
        }
    }
}

extension ReportCalendar {
    static func dayRangeTitle(startDay: String, endDay: String) -> String {
        guard let start = date(fromDayID: startDay), let end = date(fromDayID: endDay) else {
            return "\(startDay) – \(endDay)"
        }
        let formatter = dayFormatter("MMM d, yyyy")
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    private static func dayFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = gregorianUTC
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = .current
        formatter.dateFormat = format
        return formatter
    }
}
