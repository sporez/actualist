import Foundation
import GRDB

private struct RawNetWorthDay: Sendable {
    let dayID: String
    let amount: Int
}

private struct RawCalendarActivityDay: Sendable {
    let dayID: String
    let isInflow: Bool
    let amount: Int
}

private enum ReportCalendarTransferFilter: Equatable {
    case all
    case transfers
    case nonTransfers
}

extension BudgetDatabase {
    func fetchNetWorthReport(range: ReportDateRange) throws -> NetWorthReport {
        let end = ReportCalendar.dayID(month: range.anchorMonth, day: max(ReportCalendar.days(in: range.anchorMonth), 1))
        let rows = try queue.read { db in try reportNetWorthDays(through: end, db: db) }
        return try buildNetWorth(range: range, rows: rows)
    }

    func fetchReportsDashboard(range: ReportDateRange) throws -> ReportsDashboardSnapshot {
        let anchorMonthEnd = ReportCalendar.dayID(
            month: range.anchorMonth,
            day: max(ReportCalendar.days(in: range.anchorMonth), 1)
        )
        let calendarStartMonth = ReportCalendar.shiftedMonth(range.anchorMonth, by: -2)
        let calendarStartDay = ReportCalendar.dayID(month: calendarStartMonth, day: 1)
        let raw = try queue.read { db in
            let calendarTransferFilter = try reportCalendarTransferFilter(db: db)
            return (
                netWorth: try reportNetWorthDays(through: anchorMonthEnd, db: db),
                activity: try reportActivityDays(from: range.startDay, through: anchorMonthEnd, db: db),
                calendarActivity: try reportCalendarActivityDays(
                    from: calendarStartDay,
                    through: anchorMonthEnd,
                    transferFilter: calendarTransferFilter,
                    db: db
                ),
                budgetedExpenses: try reportBudgetedExpenses(month: range.anchorMonth, db: db)
            )
        }
        return try buildReportsDashboard(
            range: range,
            netWorthDays: raw.netWorth,
            activityDays: raw.activity,
            calendarActivityDays: raw.calendarActivity,
            budgetedExpenses: raw.budgetedExpenses
        )
    }

    private func reportNetWorthDays(through endDay: String, db: Database) throws -> [RawNetWorthDay] {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return []
        }

        let transactionColumns = try columnSet(for: "transactions", db: db)
        let accountColumns = try columnSet(for: "accounts", db: db)
        let split = transactionSplitQueryExpressions(columns: transactionColumns)
        let normalizedDate = normalizedDateExpression(split.qualifiedDate)

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(normalizedDate) AS day, SUM(\(split.qualifiedAmount)) AS amount
                FROM transactions t
                JOIN accounts a ON a.id = \(split.qualifiedAccount)
                \(split.parentJoin())
                WHERE \(split.liveInlinePredicate())
                  AND \(predicateForLiveRows(columns: accountColumns, tableAlias: "a"))
                  AND \(normalizedDate) <= ?
                GROUP BY \(normalizedDate)
                ORDER BY \(normalizedDate)
                """,
            arguments: [endDay]
        )

        return rows.compactMap { row in
            guard let dayID = flexibleString(row["day"]) else { return nil }
            return RawNetWorthDay(
                dayID: dayID,
                amount: row["amount"] ?? 0
            )
        }
    }

    private func reportCalendarActivityDays(
        from startDay: String,
        through endDay: String,
        transferFilter: ReportCalendarTransferFilter,
        db: Database
    ) throws -> [RawCalendarActivityDay] {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return []
        }

        let transactionColumns = try columnSet(for: "transactions", db: db)
        let accountColumns = try columnSet(for: "accounts", db: db)
        let split = transactionSplitQueryExpressions(columns: transactionColumns)
        let normalizedDate = normalizedDateExpression(split.qualifiedDate)
        let isInflowExpression = "CASE WHEN \(split.qualifiedAmount) > 0 THEN 1 ELSE 0 END"
        let transferPredicate: String
        if let transferredID = ["transferred_id", "transfer_id"].first(where: transactionColumns.contains) {
            switch transferFilter {
            case .all:
                transferPredicate = "1"
            case .transfers:
                transferPredicate = "t.\(transferredID) IS NOT NULL AND t.\(transferredID) != ''"
            case .nonTransfers:
                transferPredicate = "t.\(transferredID) IS NULL OR t.\(transferredID) = ''"
            }
        } else {
            transferPredicate = transferFilter == .transfers ? "0" : "1"
        }

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(normalizedDate) AS day,
                       \(isInflowExpression) AS is_inflow,
                       SUM(\(split.qualifiedAmount)) AS amount
                FROM transactions t
                JOIN accounts a ON a.id = \(split.qualifiedAccount)
                \(split.parentJoin())
                WHERE \(split.liveInlinePredicate())
                  AND \(predicateForLiveRows(columns: accountColumns, tableAlias: "a"))
                  AND \(normalizedDate) BETWEEN ? AND ?
                  AND (\(transferPredicate))
                GROUP BY \(normalizedDate), \(isInflowExpression)
                ORDER BY \(normalizedDate)
                """,
            arguments: [startDay, endDay]
        )

        return rows.compactMap { row in
            guard let dayID = flexibleString(row["day"]) else { return nil }
            return RawCalendarActivityDay(
                dayID: dayID,
                isInflow: flexibleBool(row["is_inflow"]),
                amount: row["amount"] ?? 0
            )
        }
    }

    private func reportCalendarTransferFilter(db: Database) throws -> ReportCalendarTransferFilter {
        guard try tableExists("dashboard", db: db) else { return .all }
        let columns = try columnSet(for: "dashboard", db: db)
        guard columns.contains("type"), columns.contains("meta") else { return .all }
        let ordering = ["y", "x"].filter(columns.contains).joined(separator: ", ")
        let orderClause = ordering.isEmpty ? "" : "ORDER BY \(ordering)"
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT meta
                FROM dashboard
                WHERE \(predicateForLiveRows(columns: columns))
                  AND type = 'calendar-card'
                \(orderClause)
                LIMIT 1
                """
        )
        guard let meta = flexibleString(row?["meta"]),
              let data = meta.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conditions = object["conditions"] as? [[String: Any]] else {
            return .all
        }

        for condition in conditions where condition["field"] as? String == "transfer" && condition["op"] as? String == "is" {
            if let value = condition["value"] as? Bool {
                return value ? .transfers : .nonTransfers
            }
            if let value = condition["value"] as? NSNumber {
                return value.boolValue ? .transfers : .nonTransfers
            }
        }
        return .all
    }

    private func buildReportsDashboard(
        range: ReportDateRange,
        netWorthDays: [RawNetWorthDay],
        activityDays: [RawReportActivityDay],
        calendarActivityDays: [RawCalendarActivityDay],
        budgetedExpenses: Int
    ) throws -> ReportsDashboardSnapshot {
        var activityByDay: [String: ReportDailyActivity] = [:]
        for row in activityDays {
            var activity = activityByDay[row.dayID] ?? ReportDailyActivity()
            if !row.isIncome {
                // Actual includes uncategorized rows and both sides of on-budget transfers.
                activity.spending = try ReportArithmetic.subtract(activity.spending, row.amount)
            }
            if row.categoryID == nil {
                if !row.isTransfer {
                    activity.uncategorized = try ReportArithmetic.add(activity.uncategorized, row.amount)
                }
            }
            if !row.isTransfer, row.isInflow {
                activity.income = try ReportArithmetic.add(activity.income, row.amount)
            } else if !row.isTransfer, row.amount < 0 {
                activity.expenses = try ReportArithmetic.subtract(activity.expenses, row.amount)
            }
            activityByDay[row.dayID] = activity
        }

        let netWorth = try buildNetWorth(range: range, rows: netWorthDays)
        let cashFlow = try buildCashFlow(range: range, activityByDay: activityByDay)
        let monthComparison = try buildMonthComparison(range: range, activityByDay: activityByDay)
        let budgetOverview = try buildBudgetOverview(
            range: range,
            activityByDay: activityByDay,
            budgetedExpenses: budgetedExpenses
        )
        let threeMonthAverage = try buildThreeMonthAverage(range: range, activityByDay: activityByDay)
        let calendar = try buildTransactionCalendar(range: range, activityDays: calendarActivityDays)

        return ReportsDashboardSnapshot(
            range: range,
            hasData: !netWorthDays.isEmpty || !activityDays.isEmpty || !calendarActivityDays.isEmpty || budgetedExpenses != 0,
            netWorth: netWorth,
            cashFlow: cashFlow,
            monthComparison: monthComparison,
            budgetOverview: budgetOverview,
            threeMonthAverage: threeMonthAverage,
            transactionCalendar: calendar
        )
    }

    private func buildNetWorth(range: ReportDateRange, rows: [RawNetWorthDay]) throws -> NetWorthReport {
        let rangeStartMonth = String(range.startDay.prefix(7))
        let pointStartMonth = rows.contains(where: { $0.dayID < range.startDay })
            ? ReportCalendar.shiftedMonth(rangeStartMonth, by: -1)
            : rangeStartMonth
        let pointStartDay = ReportCalendar.dayID(month: pointStartMonth, day: 1)
        var changeByMonth: [String: Int] = [:]
        for (month, monthRows) in Dictionary(grouping: rows, by: { String($0.dayID.prefix(7)) }) {
            changeByMonth[month] = try ReportArithmetic.sum(monthRows.map(\.amount))
        }
        var balance = try ReportArithmetic.sum(rows.filter { $0.dayID < pointStartDay }.map(\.amount))
        var points: [ReportValuePoint] = []
        for month in ReportCalendar.monthIDs(from: pointStartMonth, through: range.anchorMonth) {
            balance = try ReportArithmetic.add(balance, changeByMonth[month] ?? 0)
            points.append(
                ReportValuePoint(dayID: ReportCalendar.dayID(month: month, day: 1), value: balance)
            )
        }
        let first = points.first?.value ?? balance
        let latest = points.last?.value ?? balance
        return NetWorthReport(
            points: points,
            balance: latest,
            change: try ReportArithmetic.subtract(latest, first)
        )
    }

    private func buildCashFlow(
        range: ReportDateRange,
        activityByDay: [String: ReportDailyActivity]
    ) throws -> CashFlowSummary {
        let activities = activityByDay
            .filter { $0.key.hasPrefix(range.anchorMonth) && $0.key <= range.endDay }
            .map(\.value)
        let income = try ReportArithmetic.sum(activities.map(\.income))
        let expenses = try ReportArithmetic.sum(activities.map(\.expenses))
        let uncategorized = try ReportArithmetic.sum(activities.map(\.uncategorized))
        return CashFlowSummary(
            month: range.anchorMonth,
            income: income,
            expenses: expenses,
            net: try ReportArithmetic.subtract(income, expenses),
            uncategorized: uncategorized
        )
    }

    private func buildMonthComparison(
        range: ReportDateRange,
        activityByDay: [String: ReportDailyActivity]
    ) throws -> MonthComparisonReport {
        let comparisonMonth = ReportCalendar.shiftedMonth(range.anchorMonth, by: -1)
        let currentDay = min(max(ReportCalendar.dayNumber(from: range.endDay), 1), 28)
        var currentCumulative = 0
        var comparisonCumulative = 0
        var currentAtComparableDay = 0
        var comparisonAtComparableDay = 0
        var points: [DailyComparisonPoint] = []

        for day in 1...28 {
            let current: Int?
            if day <= currentDay {
                currentCumulative = try ReportArithmetic.add(currentCumulative, spending(
                    in: range.anchorMonth,
                    dayBucket: day,
                    activityByDay: activityByDay
                ))
                current = currentCumulative
                currentAtComparableDay = currentCumulative
            } else {
                current = nil
            }

            comparisonCumulative = try ReportArithmetic.add(comparisonCumulative, spending(
                in: comparisonMonth,
                dayBucket: day,
                activityByDay: activityByDay
            ))
            if day == currentDay {
                comparisonAtComparableDay = comparisonCumulative
            }

            points.append(
                DailyComparisonPoint(
                    day: day,
                    current: current,
                    comparison: comparisonCumulative
                )
            )
        }

        return MonthComparisonReport(
            currentMonth: range.anchorMonth,
            comparisonMonth: comparisonMonth,
            points: points,
            variance: try ReportArithmetic.subtract(currentAtComparableDay, comparisonAtComparableDay)
        )
    }

    private func buildBudgetOverview(
        range: ReportDateRange,
        activityByDay: [String: ReportDailyActivity],
        budgetedExpenses: Int
    ) throws -> BudgetOverviewReport {
        let currentDay = min(max(ReportCalendar.dayNumber(from: range.endDay), 1), 28)
        let daysInMonth = max(ReportCalendar.days(in: range.anchorMonth), 1)
        var actualCumulative = 0
        var actualPoints: [ReportValuePoint] = []
        for day in 1...currentDay {
            let dayID = ReportCalendar.dayID(month: range.anchorMonth, day: day)
            actualCumulative = try ReportArithmetic.add(actualCumulative, spending(
                in: range.anchorMonth,
                dayBucket: day,
                activityByDay: activityByDay
            ))
            actualPoints.append(ReportValuePoint(dayID: dayID, value: actualCumulative))
        }
        var budgetPoints: [ReportValuePoint] = []
        for day in 1...28 {
            let calendarDaysThroughBucket = day == 28 ? daysInMonth : day
            budgetPoints.append(ReportValuePoint(
                dayID: ReportCalendar.dayID(month: range.anchorMonth, day: day),
                value: try ReportArithmetic.scaled(
                    budgetedExpenses,
                    multiplier: calendarDaysThroughBucket,
                    divisor: daysInMonth
                )
            ))
        }
        let budgetedToDate = budgetPoints[currentDay - 1].value
        return BudgetOverviewReport(
            month: range.anchorMonth,
            actualPoints: actualPoints,
            budgetPoints: budgetPoints,
            actualExpenses: actualCumulative,
            budgetedExpenses: budgetedToDate,
            variance: try ReportArithmetic.subtract(actualCumulative, budgetedToDate)
        )
    }

    private func buildThreeMonthAverage(
        range: ReportDateRange,
        activityByDay: [String: ReportDailyActivity]
    ) throws -> ThreeMonthAverageReport {
        let historyMonths = (-3 ... -1).map { ReportCalendar.shiftedMonth(range.anchorMonth, by: $0) }
        let currentDay = min(max(ReportCalendar.dayNumber(from: range.endDay), 1), 28)
        var historyCumulative = Array(repeating: 0, count: historyMonths.count)
        var currentCumulative = 0
        var currentAtComparableDay = 0
        var averageAtComparableDay = 0
        var points: [DailyComparisonPoint] = []

        for day in 1...28 {
            let current: Int?
            if day <= currentDay {
                currentCumulative = try ReportArithmetic.add(currentCumulative, spending(
                    in: range.anchorMonth,
                    dayBucket: day,
                    activityByDay: activityByDay
                ))
                current = currentCumulative
                currentAtComparableDay = currentCumulative
            } else {
                current = nil
            }

            for (index, month) in historyMonths.enumerated() {
                historyCumulative[index] = try ReportArithmetic.add(historyCumulative[index], spending(
                    in: month,
                    dayBucket: day,
                    activityByDay: activityByDay
                ))
            }
            let average = historyCumulative.isEmpty
                ? 0
                : try ReportArithmetic.scaled(
                    ReportArithmetic.sum(historyCumulative),
                    multiplier: 1,
                    divisor: historyCumulative.count
                )
            if day == currentDay {
                averageAtComparableDay = average
            }
            points.append(DailyComparisonPoint(day: day, current: current, comparison: average))
        }

        return ThreeMonthAverageReport(
            month: range.anchorMonth,
            points: points,
            currentExpenses: currentAtComparableDay,
            averageExpenses: averageAtComparableDay,
            variance: try ReportArithmetic.subtract(currentAtComparableDay, averageAtComparableDay)
        )
    }

    // Actual folds day 28 through month-end into the last of 28 buckets.
    private func spending(
        in month: String,
        dayBucket: Int,
        activityByDay: [String: ReportDailyActivity]
    ) throws -> Int {
        let lastDay = dayBucket == 28 ? max(ReportCalendar.days(in: month), 28) : dayBucket
        var result = 0
        for day in dayBucket...lastDay {
            result = try ReportArithmetic.add(
                result,
                activityByDay[ReportCalendar.dayID(month: month, day: day)]?.spending ?? 0
            )
        }
        return result
    }

    private func buildTransactionCalendar(
        range: ReportDateRange,
        activityDays: [RawCalendarActivityDay]
    ) throws -> [TransactionCalendarMonth] {
        var displayCalendar = Calendar.current
        displayCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var activityByDay: [String: ReportDailyActivity] = [:]
        for row in activityDays {
            var activity = activityByDay[row.dayID] ?? ReportDailyActivity()
            if row.isInflow {
                activity.income = try ReportArithmetic.add(activity.income, row.amount)
            } else if row.amount < 0 {
                activity.expenses = try ReportArithmetic.subtract(activity.expenses, row.amount)
            }
            activityByDay[row.dayID] = activity
        }

        var months: [TransactionCalendarMonth] = []
        for offset in -2...0 {
            let month = ReportCalendar.shiftedMonth(range.anchorMonth, by: offset)
            let dayCount = ReportCalendar.days(in: month)
            let days = (1...max(dayCount, 1)).map { day in
                let dayID = ReportCalendar.dayID(month: month, day: day)
                let activity = activityByDay[dayID] ?? ReportDailyActivity()
                return TransactionCalendarDay(
                    dayID: dayID,
                    day: day,
                    income: activity.income,
                    expenses: activity.expenses
                )
            }
            let firstDate = ReportCalendar.date(fromMonthID: month) ?? .distantPast
            let weekday = displayCalendar.component(.weekday, from: firstDate)
            let leadingBlankCount = (weekday - displayCalendar.firstWeekday + 7) % 7
            months.append(TransactionCalendarMonth(
                month: month,
                leadingBlankCount: leadingBlankCount,
                days: days,
                income: try ReportArithmetic.sum(days.map(\.income)),
                expenses: try ReportArithmetic.sum(days.map(\.expenses))
            ))
        }
        return months
    }
}
