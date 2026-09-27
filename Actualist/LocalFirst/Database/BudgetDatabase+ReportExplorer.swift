import Foundation
import GRDB

private struct RawReportExplorerAmount: Sendable {
    let dayID: String
    let amount: Int
}

private struct ReportExplorerSpendingPrefix: Sendable {
    let dayIndex: [String: Int]
    let cumulative: [Int]

    init(spendingByDay: [String: Int], from startDay: String, through endDay: String) throws {
        var dayIndex: [String: Int] = [:]
        var cumulative: [Int] = []
        var running = 0
        for dayID in ReportCalendar.dayIDs(from: startDay, through: endDay) {
            running = try ReportArithmetic.add(running, spendingByDay[dayID] ?? 0)
            dayIndex[dayID] = cumulative.count
            cumulative.append(running)
        }
        self.dayIndex = dayIndex
        self.cumulative = cumulative
    }

    func amount(from startDay: String, through endDay: String) throws -> Int {
        guard let startIndex = dayIndex[startDay],
              let endIndex = dayIndex[endDay],
              startIndex <= endIndex else {
            return 0
        }
        let beforeStart = startIndex > 0 ? cumulative[startIndex - 1] : 0
        return try ReportArithmetic.subtract(cumulative[endIndex], beforeStart)
    }
}

extension BudgetDatabase {
    func fetchReportExplorer(query: ReportExplorerQuery) throws -> ReportExplorerSnapshot {
        if let validationError = query.validationError {
            throw validationError
        }

        switch query.metric {
        case .netWorth:
            let result = try queue.read { db in
                let catalog = try reportExplorerFilterCatalog(db: db)
                let accountIDs = reportExplorerAccountIDs(query: query, catalog: catalog)
                return (
                    try reportExplorerBalanceChanges(
                        through: query.endDay,
                        accountIDs: accountIDs,
                        db: db
                    ),
                    catalog
                )
            }
            return try buildNetWorthExplorer(query: query, rows: result.0, catalog: result.1)
        case .cashFlow, .spending, .budgetOverview, .spendingAverage:
            let result = try queue.read { db in
                let activity = try reportExplorerActivityRead(query: query, db: db)
                let currentRows = reportActivityDays(
                    from: activity.current.contributingTransactions,
                    catalog: activity.catalog
                )
                let historyRows = reportActivityDays(
                    from: activity.history?.contributingTransactions ?? [],
                    catalog: activity.catalog
                )
                let budgetedByMonth: [String: Int]
                if query.metric == .budgetOverview {
                    let categoryIDs = reportExplorerCategoryIDs(query: query, catalog: activity.catalog)
                    budgetedByMonth = try Dictionary(uniqueKeysWithValues: ReportCalendar.monthIDs(
                        from: String(query.startDay.prefix(7)),
                        through: String(query.endDay.prefix(7))
                    ).map { month in
                        (month, try reportBudgetedExpenses(
                            month: month,
                            categoryIDs: categoryIDs,
                            db: db
                        ))
                    })
                } else {
                    budgetedByMonth = [:]
                }
                return (activity, currentRows + historyRows, budgetedByMonth)
            }
            return try buildActivityExplorer(
                query: query,
                rows: result.1,
                budgetedByMonth: result.2,
                read: result.0
            )
        }
    }

    private func reportExplorerBalanceChanges(
        through endDay: String,
        accountIDs: Set<String>,
        db: Database
    ) throws -> [RawReportExplorerAmount] {
        guard try tableExists("transactions", db: db),
              try tableExists("accounts", db: db),
              !accountIDs.isEmpty else {
            return []
        }

        let transactionColumns = try columnSet(for: "transactions", db: db)
        let accountColumns = try columnSet(for: "accounts", db: db)
        let split = transactionSplitQueryExpressions(columns: transactionColumns)
        let normalizedDate = normalizedDateExpression(split.qualifiedDate)
        let sortedAccountIDs = accountIDs.sorted()
        let placeholders = Array(repeating: "?", count: sortedAccountIDs.count).joined(separator: ", ")
        var arguments: [DatabaseValueConvertible] = [endDay]
        arguments.append(contentsOf: sortedAccountIDs)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(normalizedDate) AS day,
                       SUM(\(split.qualifiedAmount)) AS amount
                FROM transactions t
                JOIN accounts a ON a.id = \(split.qualifiedAccount)
                \(split.parentJoin())
                WHERE \(split.liveInlinePredicate())
                  AND \(predicateForLiveRows(columns: accountColumns, tableAlias: "a"))
                  AND \(normalizedDate) <= ?
                  AND \(split.qualifiedAccount) IN (\(placeholders))
                GROUP BY \(normalizedDate)
                ORDER BY \(normalizedDate)
                """,
            arguments: StatementArguments(arguments)
        )
        return rows.compactMap { row in
            guard let dayID = flexibleString(row["day"]) else { return nil }
            return RawReportExplorerAmount(dayID: dayID, amount: row["amount"] ?? 0)
        }
    }

    private func buildNetWorthExplorer(
        query: ReportExplorerQuery,
        rows: [RawReportExplorerAmount],
        catalog: ReportExplorerFilterCatalog
    ) throws -> ReportExplorerSnapshot {
        let openingBalance = try ReportArithmetic.sum(rows.lazy.filter { $0.dayID < query.startDay }.map(\.amount))
        let changesByDay = try Dictionary(grouping: rows.filter { $0.dayID >= query.startDay }, by: \.dayID)
            .mapValues { try ReportArithmetic.sum($0.map(\.amount)) }
        var balance = openingBalance
        var points: [ReportExplorerPoint] = []
        for period in query.periods {
            for dayID in ReportCalendar.dayIDs(from: period.startDay, through: period.endDay) {
                balance = try ReportArithmetic.add(balance, changesByDay[dayID] ?? 0)
            }
            points.append(ReportExplorerPoint(
                period: period,
                income: 0,
                expenses: 0,
                net: 0,
                endingBalance: balance,
                budgeted: 0,
                comparison: 0
            ))
        }
        return ReportExplorerSnapshot(
            query: query,
            points: points,
            totals: ReportExplorerTotals(
                income: 0,
                expenses: 0,
                net: 0,
                endingBalance: balance,
                balanceChange: try ReportArithmetic.subtract(balance, openingBalance),
                openingBalance: openingBalance,
                budgeted: 0,
                averageSpending: 0
            ),
            hasData: !rows.isEmpty,
            filterCatalog: catalog,
            drilldown: .unavailable(.balanceSnapshot)
        )
    }

    private func buildActivityExplorer(
        query: ReportExplorerQuery,
        rows: [RawReportActivityDay],
        budgetedByMonth: [String: Int],
        read: ReportExplorerActivityRead
    ) throws -> ReportExplorerSnapshot {
        if query.metric == .spendingAverage {
            return try buildSpendingAverageExplorer(query: query, rows: rows, read: read)
        }

        let rowsByDay = Dictionary(grouping: rows, by: \.dayID)
        var points: [ReportExplorerPoint] = []
        var hasContributingData = false
        var cumulativeSpending = 0
        var cumulativeBudget = 0
        let periods = query.metric == .budgetOverview
            ? reportExplorerCumulativePeriods(query: query)
            : query.periods
        for period in periods {
            var income = 0
            var expenses = 0
            let budgeted: Int
            if query.metric == .budgetOverview {
                budgeted = try reportExplorerBudgetedAmount(
                    for: period,
                    budgetedByMonth: budgetedByMonth
                )
            } else {
                budgeted = 0
            }
            for dayID in ReportCalendar.dayIDs(from: period.startDay, through: period.endDay) {
                for row in rowsByDay[dayID] ?? [] {
                    switch query.metric {
                    case .cashFlow:
                        hasContributingData = hasContributingData || row.amount != 0
                        if row.isInflow {
                            income = try ReportArithmetic.add(income, row.amount)
                        } else if row.amount < 0 {
                            expenses = try ReportArithmetic.subtract(expenses, row.amount)
                        }
                    case .spending, .budgetOverview:
                        if !row.isIncome {
                            hasContributingData = hasContributingData || row.amount != 0
                            expenses = try ReportArithmetic.subtract(expenses, row.amount)
                        }
                    default:
                        break
                    }
                }
            }
            let pointExpenses: Int
            let pointBudgeted: Int
            if query.metric == .budgetOverview {
                cumulativeSpending = try ReportArithmetic.add(cumulativeSpending, expenses)
                cumulativeBudget = try ReportArithmetic.add(cumulativeBudget, budgeted)
                pointExpenses = cumulativeSpending
                pointBudgeted = cumulativeBudget
            } else {
                pointExpenses = expenses
                pointBudgeted = budgeted
            }
            points.append(ReportExplorerPoint(
                period: period,
                income: income,
                expenses: pointExpenses,
                net: try ReportArithmetic.subtract(income, pointExpenses),
                endingBalance: 0,
                budgeted: pointBudgeted,
                comparison: 0
            ))
        }
        let income = try ReportArithmetic.sum(points.map(\.income))
        let expenses = query.metric == .budgetOverview
            ? points.last?.expenses ?? 0
            : try ReportArithmetic.sum(points.map(\.expenses))
        let budgeted = query.metric == .budgetOverview
            ? points.last?.budgeted ?? 0
            : try ReportArithmetic.sum(points.map(\.budgeted))
        return ReportExplorerSnapshot(
            query: query,
            points: points,
            totals: ReportExplorerTotals(
                income: income,
                expenses: expenses,
                net: try ReportArithmetic.subtract(income, expenses),
                endingBalance: 0,
                balanceChange: 0,
                openingBalance: 0,
                budgeted: budgeted,
                averageSpending: 0
            ),
            hasData: hasContributingData || budgeted != 0,
            filterCatalog: read.catalog,
            drilldown: reportExplorerDrilldownAvailability(read),
            activityQuerySignature: read.current.querySignature
        )
    }

    private func buildSpendingAverageExplorer(
        query: ReportExplorerQuery,
        rows: [RawReportActivityDay],
        read: ReportExplorerActivityRead
    ) throws -> ReportExplorerSnapshot {
        guard let comparison = query.spendingAverageComparison,
              let firstHistory = comparison.history.first else {
            throw ReportExplorerError.invalidRange
        }

        let spendingByDay = try reportExplorerSpendingByDay(rows)
        let prefix = try ReportExplorerSpendingPrefix(
            spendingByDay: spendingByDay,
            from: firstHistory.startDay,
            through: query.endDay
        )
        let historyOffsets = Array(-3 ... -1)
        var points: [ReportExplorerPoint] = []
        for period in reportExplorerCumulativePeriods(query: query) {
            let current = try prefix.amount(
                from: comparison.comparison.startDay,
                through: period.endDay
            )
            let historical = try zip(historyOffsets, comparison.history).map { offset, range in
                try prefix.amount(
                    from: ReportCalendar.shiftedDay(
                        comparison.comparison.startDay,
                        byMonths: offset
                    ),
                    through: ReportCalendar.dayNumber(from: period.endDay) >= 28
                        ? range.endDay
                        : ReportCalendar.shiftedDay(period.endDay, byMonths: offset)
                )
            }
            let average = try ReportArithmetic.scaled(
                ReportArithmetic.sum(historical),
                multiplier: 1,
                divisor: comparison.history.count
            )
            points.append(ReportExplorerPoint(
                period: period,
                income: 0,
                expenses: current,
                net: try ReportArithmetic.subtract(0, current),
                endingBalance: 0,
                budgeted: 0,
                comparison: average
            ))
        }
        let current = points.last?.expenses ?? 0
        let average = points.last?.comparison ?? 0
        return ReportExplorerSnapshot(
            query: query,
            points: points,
            totals: ReportExplorerTotals(
                income: 0,
                expenses: current,
                net: try ReportArithmetic.subtract(0, current),
                endingBalance: 0,
                balanceChange: 0,
                openingBalance: 0,
                budgeted: 0,
                averageSpending: average
            ),
            hasData: points.contains { $0.expenses != 0 || $0.comparison != 0 },
            filterCatalog: read.catalog,
            drilldown: reportExplorerDrilldownAvailability(read),
            activityQuerySignature: read.current.querySignature,
            historyQuerySignature: read.history?.querySignature
        )
    }

    private func reportExplorerDrilldownAvailability(
        _ read: ReportExplorerActivityRead
    ) -> ReportDrilldownAvailability {
        read.current.contributingTransactions.isEmpty
            ? .unavailable(.noContributingTransactions)
            : .transactions(read.currentRequest)
    }

    private func reportExplorerSpendingByDay(
        _ rows: [RawReportActivityDay]
    ) throws -> [String: Int] {
        var spendingByDay: [String: Int] = [:]
        for row in rows where !row.isIncome {
            let spending = try ReportArithmetic.subtract(0, row.amount)
            spendingByDay[row.dayID] = try ReportArithmetic.add(
                spendingByDay[row.dayID] ?? 0,
                spending
            )
        }
        return spendingByDay
    }

    /// Actual's cumulative spending graphs use one bucket per calendar day
    /// through day 27, then fold day 28 through month-end into the final bucket.
    private func reportExplorerCumulativePeriods(
        query: ReportExplorerQuery
    ) -> [ReportExplorerPeriod] {
        guard query.interval == .day else { return query.periods }

        var periods: [ReportExplorerPeriod] = []
        for month in ReportCalendar.monthIDs(
            from: String(query.startDay.prefix(7)),
            through: String(query.endDay.prefix(7))
        ) {
            let monthStart = ReportCalendar.dayID(month: month, day: 1)
            let monthEnd = ReportCalendar.dayID(
                month: month,
                day: max(ReportCalendar.days(in: month), 1)
            )
            let startDay = max(query.startDay, monthStart)
            let endDay = min(query.endDay, monthEnd)
            let startNumber = ReportCalendar.dayNumber(from: startDay)
            let endNumber = ReportCalendar.dayNumber(from: endDay)

            if startNumber <= min(endNumber, 27) {
                for day in startNumber ... min(endNumber, 27) {
                    let dayID = ReportCalendar.dayID(month: month, day: day)
                    periods.append(ReportExplorerPeriod(startDay: dayID, endDay: dayID))
                }
            }
            if endNumber >= 28 {
                periods.append(ReportExplorerPeriod(
                    startDay: max(startDay, ReportCalendar.dayID(month: month, day: 28)),
                    endDay: endDay
                ))
            }
        }
        return periods
    }

    private func reportExplorerBudgetedAmount(
        for period: ReportExplorerPeriod,
        budgetedByMonth: [String: Int]
    ) throws -> Int {
        var amount = 0
        for month in ReportCalendar.monthIDs(
            from: String(period.startDay.prefix(7)),
            through: String(period.endDay.prefix(7))
        ) {
            let dayCount = max(ReportCalendar.days(in: month), 1)
            let firstDay = month == String(period.startDay.prefix(7))
                ? ReportCalendar.dayNumber(from: period.startDay)
                : 1
            let lastDay = month == String(period.endDay.prefix(7))
                ? ReportCalendar.dayNumber(from: period.endDay)
                : dayCount
            let monthlyAmount = budgetedByMonth[month] ?? 0
            let throughLastDay = try ReportArithmetic.scaled(
                monthlyAmount,
                multiplier: lastDay,
                divisor: dayCount
            )
            let beforeFirstDay = try ReportArithmetic.scaled(
                monthlyAmount,
                multiplier: max(firstDay - 1, 0),
                divisor: dayCount
            )
            amount = try ReportArithmetic.add(
                amount,
                ReportArithmetic.subtract(throughLastDay, beforeFirstDay)
            )
        }
        return amount
    }
}
