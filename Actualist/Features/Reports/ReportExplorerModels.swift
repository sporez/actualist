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

/// Caps the number of periods one explorer query can generate (D6c).
enum ReportExplorerRangeLimits {
    static let maximumDays = 1_100
    static let maximumMonths = 600

    /// Inclusive span of the range in the unit the interval buckets by.
    static func exceeds(startDay: String, endDay: String, interval: ReportInterval) -> Bool {
        switch interval {
        case .day:
            guard let start = ReportCalendar.date(fromDayID: startDay),
                  let end = ReportCalendar.date(fromDayID: endDay) else { return false }
            let days = ReportCalendar.gregorianUTC.dateComponents([.day], from: start, to: end).day ?? 0
            return days + 1 > maximumDays
        case .month:
            guard let start = monthNumber(startDay), let end = monthNumber(endDay) else { return false }
            return end - start + 1 > maximumMonths
        }
    }

    /// Latest end and earliest start the custom range pickers should offer
    /// for a fixed opposite bound, so a picker cannot build an oversized range.
    static func earliestStart(forEnd end: Date, interval: ReportInterval) -> Date {
        let calendar = ReportCalendar.gregorianUTC
        switch interval {
        case .day:
            return calendar.date(byAdding: .day, value: -(maximumDays - 1), to: end) ?? end
        case .month:
            return calendar.date(byAdding: .month, value: -(maximumMonths - 1), to: end) ?? end
        }
    }

    static func latestEnd(forStart start: Date, interval: ReportInterval) -> Date {
        let calendar = ReportCalendar.gregorianUTC
        switch interval {
        case .day:
            return calendar.date(byAdding: .day, value: maximumDays - 1, to: start) ?? start
        case .month:
            return calendar.date(byAdding: .month, value: maximumMonths - 1, to: start) ?? start
        }
    }

    private static func monthNumber(_ dayID: String) -> Int? {
        let parts = dayID.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
        return year * 12 + month
    }
}

struct ReportExplorerQuery: Hashable, Sendable {
    let metric: ReportExplorerMetric
    let startDay: String
    let endDay: String
    let interval: ReportInterval
    let filters: ReportExplorerFilters

    init(
        metric: ReportExplorerMetric,
        startDay: String,
        endDay: String,
        interval: ReportInterval,
        filters: ReportExplorerFilters = .default
    ) {
        self.metric = metric
        self.startDay = startDay
        self.endDay = endDay
        self.interval = interval
        self.filters = filters
    }

    var hasValidRange: Bool {
        validationError == nil
    }

    var validationError: ReportExplorerError? {
        guard ReportCalendar.date(fromDayID: startDay) != nil,
              ReportCalendar.date(fromDayID: endDay) != nil else {
            return .invalidRange
        }
        guard startDay <= endDay else { return .invalidRange }
        if ReportExplorerRangeLimits.exceeds(startDay: startDay, endDay: endDay, interval: interval) {
            return .rangeTooLarge
        }
        if metric == .spendingAverage,
           String(startDay.prefix(7)) != String(endDay.prefix(7)) {
            return .spendingAverageRequiresSingleMonth
        }
        if metric == .netWorth,
           (!filters.categories.isAll
            || !filters.includesHiddenCategories
            || !filters.includesUncategorized) {
            return .unsupportedNetWorthCategoryFilter
        }
        return nil
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
    let filterCatalog: ReportExplorerFilterCatalog
    let drilldown: ReportDrilldownAvailability
    let activityQuerySignature: TransactionQuerySignature?
    let historyQuerySignature: TransactionQuerySignature?

    init(
        query: ReportExplorerQuery,
        points: [ReportExplorerPoint],
        totals: ReportExplorerTotals,
        hasData: Bool,
        filterCatalog: ReportExplorerFilterCatalog = .empty,
        drilldown: ReportDrilldownAvailability = .unavailable(.noContributingTransactions),
        activityQuerySignature: TransactionQuerySignature? = nil,
        historyQuerySignature: TransactionQuerySignature? = nil
    ) {
        self.query = query
        self.points = points
        self.totals = totals
        self.hasData = hasData
        self.filterCatalog = filterCatalog
        self.drilldown = drilldown
        self.activityQuerySignature = activityQuerySignature
        self.historyQuerySignature = historyQuerySignature
    }
}

enum ReportExplorerError: LocalizedError, Equatable {
    case invalidRange
    case rangeTooLarge
    case spendingAverageRequiresSingleMonth
    case unsupportedNetWorthCategoryFilter

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            "The report start date must be on or before its end date."
        case .rangeTooLarge:
            "That range is too long. Choose up to \(ReportExplorerRangeLimits.maximumDays) days for daily "
                + "reports or \(ReportExplorerRangeLimits.maximumMonths) months for monthly reports."
        case .spendingAverageRequiresSingleMonth:
            "Spending Average compares one month at a time."
        case .unsupportedNetWorthCategoryFilter:
            "Net Worth supports account filters, not category filters."
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
