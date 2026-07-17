import Foundation
import Observation

enum ReportValueTone: Equatable {
    case neutral
    case positive
    case warning
    case danger
}

@MainActor
@Observable
final class ReportsViewModel {
    private(set) var snapshot: ReportsDashboardSnapshot?
    private(set) var displaySnapshot: ReportsDashboardSnapshot?
    private(set) var range: ReportDateRange?
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private(set) var isPrivacyModeEnabled = false

    func load(using appState: AppState, now: Date = Date()) async {
        guard let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeReportsRepository() else {
            errorMessage = "Open a budget before loading reports."
            return
        }

        await load(
            budgetID: budgetID,
            repository: repository,
            privacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
            now: now,
            refreshRemote: {
                await appState.refreshLocalFirstData(budgetID: budgetID)
            }
        )
    }

    func load(
        budgetID: String,
        repository: any ReportsRepositoryProtocol,
        privacyModeEnabled: Bool,
        now: Date,
        refreshRemote: @escaping @MainActor () async -> Void = {}
    ) async {
        let requestedRange = ReportDateRange.dashboard(through: now)
        range = requestedRange
        isPrivacyModeEnabled = privacyModeEnabled
        errorMessage = nil

        if let cached = repository.cachedReportsDashboard(budgetID: budgetID, range: requestedRange) {
            apply(cached)
        }

        isLoading = snapshot == nil
        do {
            apply(try await repository.refreshReportsDashboard(budgetID: budgetID, range: requestedRange))
        } catch {
            if snapshot == nil {
                errorMessage = error.localizedDescription
            }
            isLoading = false
            return
        }
        isLoading = false

        isRefreshing = true
        await refreshRemote()
        do {
            apply(try await repository.refreshReportsDashboard(budgetID: budgetID, range: requestedRange))
        } catch {
            errorMessage = snapshot == nil ? error.localizedDescription : nil
        }
        isRefreshing = false
    }

    func updatePrivacyMode(_ isEnabled: Bool) {
        isPrivacyModeEnabled = isEnabled
        if let snapshot {
            displaySnapshot = sanitized(snapshot)
        }
    }

    var netWorthSubtitle: String {
        guard let range else { return "" }
        return ReportCalendar.rangeTitle(startDay: range.startDay, endDay: range.endDay)
    }

    var netWorthHeadline: String { money(displaySnapshot?.netWorth.balance ?? 0) }
    var netWorthChangeText: String { signedMoney(displaySnapshot?.netWorth.change ?? 0) }
    var netWorthTone: ReportValueTone { comparisonTone(displaySnapshot?.netWorth.change ?? 0) }

    var cashFlowSubtitle: String {
        displaySnapshot.map { ReportCalendar.monthTitle($0.cashFlow.month) } ?? ""
    }
    var cashFlowHeadline: String { signedMoney(displaySnapshot?.cashFlow.net ?? 0) }
    var cashFlowTone: ReportValueTone { comparisonTone(displaySnapshot?.cashFlow.net ?? 0) }
    var cashFlowIncomeText: String { money(displaySnapshot?.cashFlow.income ?? 0) }
    var cashFlowExpenseText: String { money(displaySnapshot?.cashFlow.expenses ?? 0) }
    var uncategorizedText: String? {
        guard let value = displaySnapshot?.cashFlow.uncategorized, value != 0 else { return nil }
        return "Uncategorized activity: \(money(value))"
    }

    var monthComparisonSubtitle: String {
        guard let report = displaySnapshot?.monthComparison else { return "" }
        return "Compare \(ReportCalendar.shortMonthTitle(report.currentMonth)) to \(ReportCalendar.shortMonthTitle(report.comparisonMonth))"
    }
    var monthComparisonHeadline: String { signedMoney(displaySnapshot?.monthComparison.variance ?? 0) }
    var monthComparisonTone: ReportValueTone { overspendingTone(displaySnapshot?.monthComparison.variance ?? 0) }

    var budgetOverviewSubtitle: String {
        guard let month = displaySnapshot?.budgetOverview.month else { return "" }
        return "Compare \(ReportCalendar.shortMonthTitle(month)) to budgeted"
    }
    var budgetOverviewHeadline: String { signedMoney(displaySnapshot?.budgetOverview.variance ?? 0) }
    var budgetOverviewTone: ReportValueTone { overspendingTone(displaySnapshot?.budgetOverview.variance ?? 0) }

    var threeMonthAverageSubtitle: String {
        guard let month = displaySnapshot?.threeMonthAverage.month else { return "" }
        return "Compare \(ReportCalendar.shortMonthTitle(month)) to the last 3 months"
    }
    var threeMonthAverageHeadline: String { signedMoney(displaySnapshot?.threeMonthAverage.variance ?? 0) }
    var threeMonthAverageTone: ReportValueTone { overspendingTone(displaySnapshot?.threeMonthAverage.variance ?? 0) }

    var calendarRangeTitle: String {
        guard let months = displaySnapshot?.transactionCalendar,
              let first = months.first?.month,
              let last = months.last?.month else {
            return ""
        }
        return "\(ReportCalendar.shortMonthTitle(first)) – \(ReportCalendar.shortMonthTitle(last))"
    }

    var weekdaySymbols: [String] {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard !symbols.isEmpty else { return ["S", "M", "T", "W", "T", "F", "S"] }
        let offset = max(calendar.firstWeekday - 1, 0)
        return Array(symbols[offset...] + symbols[..<offset])
    }

    func axisLabel(_ value: Int) -> String {
        let dollars = Double(value) / 100
        let absolute = abs(dollars)
        let symbol = Locale.current.currencySymbol ?? "$"
        let sign = dollars < 0 ? "−" : ""
        if absolute >= 1_000_000 {
            return "\(sign)\(symbol)\(String(format: "%.1fM", absolute / 1_000_000))"
        }
        if absolute >= 1_000 {
            return "\(sign)\(symbol)\(String(format: "%.1fK", absolute / 1_000))"
        }
        return "\(sign)\(symbol)\(String(format: "%.0f", absolute))"
    }

    func calendarIntensity(_ amount: Int) -> Double {
        guard amount != 0, calendarMaximum > 0 else { return 0 }
        return max(0.22, min(Double(abs(amount)) / Double(calendarMaximum), 1))
    }

    func calendarDayAccessibility(_ day: TransactionCalendarDay) -> String {
        let date = ReportCalendar.longDayTitle(day.dayID)
        return "\(date), income \(money(day.income)), expenses \(money(day.expenses))"
    }

    func calendarMonthIncome(_ month: TransactionCalendarMonth) -> String { money(month.income) }
    func calendarMonthExpenses(_ month: TransactionCalendarMonth) -> String { money(month.expenses) }

    var netWorthAccessibility: String {
        "Net worth \(netWorthHeadline), change \(netWorthChangeText), \(netWorthSubtitle)"
    }
    var cashFlowAccessibility: String {
        "Cash flow \(cashFlowHeadline), income \(cashFlowIncomeText), expenses \(cashFlowExpenseText), \(cashFlowSubtitle)"
    }
    var monthComparisonAccessibility: String {
        "This month comparison \(monthComparisonHeadline). \(monthComparisonSubtitle)"
    }
    var budgetOverviewAccessibility: String {
        "Budget overview variance \(budgetOverviewHeadline). \(budgetOverviewSubtitle)"
    }
    var threeMonthAverageAccessibility: String {
        "Three month average variance \(threeMonthAverageHeadline). \(threeMonthAverageSubtitle)"
    }

    private var calendarMaximum: Int {
        displaySnapshot?.transactionCalendar
            .flatMap(\.days)
            .reduce(0) { max($0, max(abs($1.income), abs($1.expenses))) } ?? 0
    }

    private func apply(_ snapshot: ReportsDashboardSnapshot) {
        self.snapshot = snapshot
        displaySnapshot = sanitized(snapshot)
    }

    private func sanitized(_ snapshot: ReportsDashboardSnapshot) -> ReportsDashboardSnapshot {
        guard isPrivacyModeEnabled else { return snapshot }

        let netWorthPoints = snapshot.netWorth.points.map {
            ReportValuePoint(dayID: $0.dayID, value: masked($0.value, seed: "reports-net-worth-\($0.dayID)", maximumDollars: 250_000))
        }
        let netWorthBalance = netWorthPoints.last?.value ?? 0
        let netWorthChange = netWorthBalance - (netWorthPoints.first?.value ?? netWorthBalance)

        let income = masked(snapshot.cashFlow.income, seed: "reports-cash-income", maximumDollars: 25_000)
        let expenses = masked(snapshot.cashFlow.expenses, seed: "reports-cash-expenses", maximumDollars: 25_000)
        let uncategorized = masked(snapshot.cashFlow.uncategorized, seed: "reports-cash-uncategorized", maximumDollars: 2_500)

        let monthPoints = snapshot.monthComparison.points.map { point in
            DailyComparisonPoint(
                day: point.day,
                current: point.current.map { masked($0, seed: "reports-month-current-\(point.day)", maximumDollars: 25_000) },
                comparison: masked(point.comparison, seed: "reports-month-previous-\(point.day)", maximumDollars: 25_000)
            )
        }
        let lastComparableMonth = monthPoints.last(where: { $0.current != nil })
        let monthVariance = (lastComparableMonth?.current ?? 0) - (lastComparableMonth?.comparison ?? 0)

        let budgetActual = snapshot.budgetOverview.actualPoints.map {
            ReportValuePoint(dayID: $0.dayID, value: masked($0.value, seed: "reports-budget-actual-\($0.dayID)", maximumDollars: 25_000))
        }
        let budgetReference = snapshot.budgetOverview.budgetPoints.map {
            ReportValuePoint(dayID: $0.dayID, value: masked($0.value, seed: "reports-budget-reference-\($0.dayID)", maximumDollars: 25_000))
        }
        let budgetActualTotal = budgetActual.last?.value ?? 0
        let budgetReferenceTotal = budgetActual.indices.last.map { budgetReference[$0].value } ?? 0

        let averagePoints = snapshot.threeMonthAverage.points.map { point in
            DailyComparisonPoint(
                day: point.day,
                current: point.current.map { masked($0, seed: "reports-average-current-\(point.day)", maximumDollars: 25_000) },
                comparison: masked(point.comparison, seed: "reports-average-history-\(point.day)", maximumDollars: 25_000)
            )
        }
        let lastComparableAverage = averagePoints.last(where: { $0.current != nil })
        let currentExpenses = lastComparableAverage?.current ?? 0
        let averageExpenses = lastComparableAverage?.comparison ?? 0

        let calendar = snapshot.transactionCalendar.map { month in
            let days = month.days.map { day in
                TransactionCalendarDay(
                    dayID: day.dayID,
                    day: day.day,
                    income: masked(day.income, seed: "reports-calendar-income-\(day.dayID)", maximumDollars: 5_000),
                    expenses: masked(day.expenses, seed: "reports-calendar-expenses-\(day.dayID)", maximumDollars: 5_000)
                )
            }
            return TransactionCalendarMonth(
                month: month.month,
                leadingBlankCount: month.leadingBlankCount,
                days: days,
                income: days.reduce(0) { $0 + $1.income },
                expenses: days.reduce(0) { $0 + $1.expenses }
            )
        }

        return ReportsDashboardSnapshot(
            range: snapshot.range,
            hasData: snapshot.hasData,
            netWorth: NetWorthReport(points: netWorthPoints, balance: netWorthBalance, change: netWorthChange),
            cashFlow: CashFlowSummary(
                month: snapshot.cashFlow.month,
                income: income,
                expenses: expenses,
                net: income - expenses,
                uncategorized: uncategorized
            ),
            monthComparison: MonthComparisonReport(
                currentMonth: snapshot.monthComparison.currentMonth,
                comparisonMonth: snapshot.monthComparison.comparisonMonth,
                points: monthPoints,
                variance: monthVariance
            ),
            budgetOverview: BudgetOverviewReport(
                month: snapshot.budgetOverview.month,
                actualPoints: budgetActual,
                budgetPoints: budgetReference,
                actualExpenses: budgetActualTotal,
                budgetedExpenses: budgetReferenceTotal,
                variance: budgetActualTotal - budgetReferenceTotal
            ),
            threeMonthAverage: ThreeMonthAverageReport(
                month: snapshot.threeMonthAverage.month,
                points: averagePoints,
                currentExpenses: currentExpenses,
                averageExpenses: averageExpenses,
                variance: currentExpenses - averageExpenses
            ),
            transactionCalendar: calendar
        )
    }

    private func masked(_ amount: Int, seed: String, maximumDollars: Int) -> Int {
        guard amount != 0 else { return 0 }
        return PrivacyDisplay.amount(
            amount,
            seed: seed,
            minimumDollars: 4,
            maximumDollars: maximumDollars
        )
    }

    private func money(_ amount: Int) -> String {
        amount.actualMoney.formatted()
    }

    private func signedMoney(_ amount: Int) -> String {
        if amount > 0 { return "+\(money(amount))" }
        return money(amount)
    }

    private func comparisonTone(_ amount: Int) -> ReportValueTone {
        if amount > 0 { return .positive }
        if amount < 0 { return .danger }
        return .neutral
    }

    private func overspendingTone(_ amount: Int) -> ReportValueTone {
        if amount > 0 { return .danger }
        if amount < 0 { return .positive }
        return .neutral
    }
}
