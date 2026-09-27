import Foundation
import GRDB

private struct RawReportExplorerAmount: Sendable {
    let dayID: String
    let amount: Int
}

extension BudgetDatabase {
    func fetchReportExplorer(query: ReportExplorerQuery) throws -> ReportExplorerSnapshot {
        guard query.hasValidRange else { throw ReportExplorerError.invalidRange }

        switch query.metric {
        case .netWorth:
            let rows = try queue.read { db in
                try reportExplorerBalanceChanges(through: query.endDay, db: db)
            }
            return try buildNetWorthExplorer(query: query, rows: rows)
        case .cashFlow, .spending, .budgetOverview, .spendingAverage:
            let result = try queue.read { db in
                let rows = try reportActivityDays(
                    from: query.startDay,
                    through: query.endDay,
                    db: db
                )
                let budgetedByMonth: [String: Int]
                if query.metric == .budgetOverview {
                    budgetedByMonth = try Dictionary(uniqueKeysWithValues: ReportCalendar.monthIDs(
                        from: String(query.startDay.prefix(7)),
                        through: String(query.endDay.prefix(7))
                    ).map { month in
                        (month, try reportBudgetedExpenses(month: month, db: db))
                    })
                } else {
                    budgetedByMonth = [:]
                }
                return (rows, budgetedByMonth)
            }
            return try buildActivityExplorer(
                query: query,
                rows: result.0,
                budgetedByMonth: result.1
            )
        }
    }

    private func reportExplorerBalanceChanges(
        through endDay: String,
        db: Database
    ) throws -> [RawReportExplorerAmount] {
        guard try tableExists("transactions", db: db),
              try tableExists("accounts", db: db) else {
            return []
        }

        let transactionColumns = try columnSet(for: "transactions", db: db)
        let accountColumns = try columnSet(for: "accounts", db: db)
        let split = transactionSplitQueryExpressions(columns: transactionColumns)
        let normalizedDate = normalizedDateExpression(split.qualifiedDate)
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
                GROUP BY \(normalizedDate)
                ORDER BY \(normalizedDate)
                """,
            arguments: [endDay]
        )
        return rows.compactMap { row in
            guard let dayID = flexibleString(row["day"]) else { return nil }
            return RawReportExplorerAmount(dayID: dayID, amount: row["amount"] ?? 0)
        }
    }

    private func buildNetWorthExplorer(
        query: ReportExplorerQuery,
        rows: [RawReportExplorerAmount]
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
                budgeted: 0
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
            hasData: !rows.isEmpty
        )
    }

    private func buildActivityExplorer(
        query: ReportExplorerQuery,
        rows: [RawReportActivityDay],
        budgetedByMonth: [String: Int]
    ) throws -> ReportExplorerSnapshot {
        let rowsByDay = Dictionary(grouping: rows, by: \.dayID)
        var points: [ReportExplorerPoint] = []
        var hasContributingData = false
        for period in query.periods {
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
                    case .cashFlow where !row.isTransfer:
                        hasContributingData = hasContributingData || row.amount != 0
                        if row.isInflow {
                            income = try ReportArithmetic.add(income, row.amount)
                        } else if row.amount < 0 {
                            expenses = try ReportArithmetic.subtract(expenses, row.amount)
                        }
                    case .spending, .budgetOverview, .spendingAverage:
                        if !row.isIncome {
                            hasContributingData = hasContributingData || row.amount != 0
                            expenses = try ReportArithmetic.subtract(expenses, row.amount)
                        }
                    default:
                        break
                    }
                }
            }
            points.append(ReportExplorerPoint(
                period: period,
                income: income,
                expenses: expenses,
                net: try ReportArithmetic.subtract(income, expenses),
                endingBalance: 0,
                budgeted: budgeted
            ))
        }
        let income = try ReportArithmetic.sum(points.map(\.income))
        let expenses = try ReportArithmetic.sum(points.map(\.expenses))
        let budgeted = try ReportArithmetic.sum(points.map(\.budgeted))
        let averageSpending = query.metric == .spendingAverage && !points.isEmpty
            ? try ReportArithmetic.scaled(expenses, multiplier: 1, divisor: points.count)
            : 0
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
                averageSpending: averageSpending
            ),
            hasData: hasContributingData || budgeted != 0
        )
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
