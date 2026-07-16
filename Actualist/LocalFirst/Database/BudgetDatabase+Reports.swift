import Foundation
import GRDB

private struct RawNetWorthDay: Sendable {
    let dayID: String
    let amount: Int
}

private struct RawReportActivityDay: Sendable {
    let dayID: String
    let categoryID: String?
    let isIncome: Bool
    let isTransfer: Bool
    let amount: Int
}

extension BudgetDatabase {
    func fetchReportsDashboard(range: ReportDateRange) throws -> ReportsDashboardSnapshot {
        let raw = try queue.read { db in
            (
                netWorth: try reportNetWorthDays(through: range.endDay, db: db),
                activity: try reportActivityDays(from: range.startDay, through: range.endDay, db: db),
                budgetedExpenses: try reportBudgetedExpenses(month: range.anchorMonth, db: db)
            )
        }
        return buildReportsDashboard(
            range: range,
            netWorthDays: raw.netWorth,
            activityDays: raw.activity,
            budgetedExpenses: raw.budgetedExpenses
        )
    }

    private func reportNetWorthDays(through endDay: String, db: Database) throws -> [RawNetWorthDay] {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return []
        }

        let transactionColumns = try columnSet(for: "transactions", db: db)
        let accountColumns = try columnSet(for: "accounts", db: db)
        let account = column("acct", fallback: column("account", fallback: "NULL", columns: transactionColumns), columns: transactionColumns)
        let amount = column("amount", fallback: "0", columns: transactionColumns)
        let date = column("date", fallback: "NULL", columns: transactionColumns)
        let parentID = column("parent_id", fallback: "NULL", columns: transactionColumns)
        let isParent = column(
            "isParent",
            fallback: column("is_parent", fallback: "0", columns: transactionColumns),
            columns: transactionColumns
        )
        let normalizedDate = normalizedDateExpression("t.\(date)")

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(normalizedDate) AS day, SUM(t.\(amount)) AS amount
                FROM transactions t
                JOIN accounts a ON a.id = t.\(account)
                LEFT JOIN transactions parent ON parent.id = t.\(parentID)
                WHERE \(predicateForLiveRows(columns: transactionColumns, tableAlias: "t"))
                  AND \(predicateForLiveRows(columns: accountColumns, tableAlias: "a"))
                  AND (t.\(parentID) IS NULL OR \(predicateForLiveRows(columns: transactionColumns, tableAlias: "parent")))
                  AND (t.\(isParent) = 0 OR t.\(isParent) IS NULL)
                  AND t.\(date) IS NOT NULL
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
                amount: actualAmountToMinorUnits(row["amount"] ?? 0)
            )
        }
    }

    private func reportActivityDays(
        from startDay: String,
        through endDay: String,
        db: Database
    ) throws -> [RawReportActivityDay] {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return []
        }

        let transactionColumns = try columnSet(for: "transactions", db: db)
        let accountColumns = try columnSet(for: "accounts", db: db)
        let account = column("acct", fallback: column("account", fallback: "NULL", columns: transactionColumns), columns: transactionColumns)
        let amount = column("amount", fallback: "0", columns: transactionColumns)
        let category = column("category", fallback: "NULL", columns: transactionColumns)
        let date = column("date", fallback: "NULL", columns: transactionColumns)
        let parentID = column("parent_id", fallback: "NULL", columns: transactionColumns)
        let isParent = column(
            "isParent",
            fallback: column("is_parent", fallback: "0", columns: transactionColumns),
            columns: transactionColumns
        )
        let offBudget = column("offbudget", fallback: "0", columns: accountColumns)
        let normalizedDate = normalizedDateExpression("t.\(date)")

        let hasCategoryMapping = try tableExists("category_mapping", db: db)
        let mappedCategory: String
        let categoryMappingJoin: String
        if hasCategoryMapping {
            let mappingColumns = try columnSet(for: "category_mapping", db: db)
            if let transferCategory = ["transferId", "transfer_id"].first(where: mappingColumns.contains) {
                mappedCategory = "COALESCE(cm.\(transferCategory), t.\(category))"
                categoryMappingJoin = "LEFT JOIN category_mapping cm ON cm.id = t.\(category)"
            } else {
                mappedCategory = "t.\(category)"
                categoryMappingJoin = ""
            }
        } else {
            mappedCategory = "t.\(category)"
            categoryMappingJoin = ""
        }

        let hasCategories = try tableExists("categories", db: db)
        let hasCategoryGroups = hasCategories ? try tableExists("category_groups", db: db) : false
        let categoryJoin: String
        let groupJoin: String
        let isIncomeExpression: String
        if hasCategories {
            let categoryColumns = try columnSet(for: "categories", db: db)
            let categoryIncome = column("is_income", fallback: "0", columns: categoryColumns)
            let categoryGroup = column(
                "cat_group",
                fallback: column("group_id", fallback: "NULL", columns: categoryColumns),
                columns: categoryColumns
            )
            categoryJoin = "LEFT JOIN categories c ON c.id = \(mappedCategory)"
            if hasCategoryGroups {
                let groupColumns = try columnSet(for: "category_groups", db: db)
                let groupIncome = column("is_income", fallback: "0", columns: groupColumns)
                groupJoin = "LEFT JOIN category_groups g ON g.id = c.\(categoryGroup)"
                isIncomeExpression = "CASE WHEN COALESCE(c.\(categoryIncome), 0) != 0 OR COALESCE(g.\(groupIncome), 0) != 0 THEN 1 ELSE 0 END"
            } else {
                groupJoin = ""
                isIncomeExpression = "CASE WHEN COALESCE(c.\(categoryIncome), 0) != 0 THEN 1 ELSE 0 END"
            }
        } else {
            categoryJoin = ""
            groupJoin = ""
            isIncomeExpression = "0"
        }

        let transactionTransferColumns = ["transferred_id", "transfer_id"].filter(transactionColumns.contains)
        var transferPredicates = transactionTransferColumns.map { "(t.\($0) IS NOT NULL AND t.\($0) != '')" }
        var payeeJoin = ""
        if try tableExists("payees", db: db),
           let payeeColumn = ["description", "payee"].first(where: transactionColumns.contains) {
            let payeeColumns = try columnSet(for: "payees", db: db)
            if let transferAccount = ["transfer_acct", "transfer_account"].first(where: payeeColumns.contains) {
                payeeJoin = "LEFT JOIN payees py ON py.id = t.\(payeeColumn)"
                transferPredicates.append("(py.\(transferAccount) IS NOT NULL AND py.\(transferAccount) != '')")
            }
        }
        let isTransferExpression = transferPredicates.isEmpty
            ? "0"
            : "CASE WHEN \(transferPredicates.joined(separator: " OR ")) THEN 1 ELSE 0 END"

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(normalizedDate) AS day,
                       \(mappedCategory) AS category_id,
                       \(isIncomeExpression) AS is_income,
                       \(isTransferExpression) AS is_transfer,
                       SUM(t.\(amount)) AS amount
                FROM transactions t
                JOIN accounts a ON a.id = t.\(account)
                LEFT JOIN transactions parent ON parent.id = t.\(parentID)
                \(categoryMappingJoin)
                \(categoryJoin)
                \(groupJoin)
                \(payeeJoin)
                WHERE \(predicateForLiveRows(columns: transactionColumns, tableAlias: "t"))
                  AND \(predicateForLiveRows(columns: accountColumns, tableAlias: "a"))
                  AND (t.\(parentID) IS NULL OR \(predicateForLiveRows(columns: transactionColumns, tableAlias: "parent")))
                  AND (t.\(isParent) = 0 OR t.\(isParent) IS NULL)
                  AND COALESCE(a.\(offBudget), 0) = 0
                  AND t.\(date) IS NOT NULL
                  AND \(normalizedDate) BETWEEN ? AND ?
                GROUP BY \(normalizedDate), \(mappedCategory), \(isIncomeExpression), \(isTransferExpression)
                ORDER BY \(normalizedDate)
                """,
            arguments: [startDay, endDay]
        )

        return rows.compactMap { row in
            guard let dayID = flexibleString(row["day"]) else { return nil }
            let categoryID = (row["category_id"] as String?).flatMap { $0.isEmpty ? nil : $0 }
            return RawReportActivityDay(
                dayID: dayID,
                categoryID: categoryID,
                isIncome: flexibleBool(row["is_income"]),
                isTransfer: flexibleBool(row["is_transfer"]),
                amount: actualAmountToMinorUnits(row["amount"] ?? 0)
            )
        }
    }

    private func reportBudgetedExpenses(month: String, db: Database) throws -> Int {
        guard try tableExists("zero_budgets", db: db) else { return 0 }

        let budgetColumns = try columnSet(for: "zero_budgets", db: db)
        let budgetCategory = column("category", fallback: "NULL", columns: budgetColumns)
        let budgetAmount = column("amount", fallback: "0", columns: budgetColumns)
        let budgetMonth = column("month", fallback: "NULL", columns: budgetColumns)
        let normalizedMonth = normalizedMonthExpression("z.\(budgetMonth)")

        guard try tableExists("categories", db: db) else {
            let row = try Row.fetchOne(
                db,
                sql: "SELECT SUM(z.\(budgetAmount)) AS amount FROM zero_budgets z WHERE \(normalizedMonth) = ?",
                arguments: [month]
            )
            return actualAmountToMinorUnits(row?["amount"] ?? 0)
        }

        let categoryColumns = try columnSet(for: "categories", db: db)
        let categoryIncome = column("is_income", fallback: "0", columns: categoryColumns)
        let categoryGroup = column(
            "cat_group",
            fallback: column("group_id", fallback: "NULL", columns: categoryColumns),
            columns: categoryColumns
        )
        let hasGroups = try tableExists("category_groups", db: db)
        let groupJoin: String
        let isIncomeExpression: String
        if hasGroups {
            let groupColumns = try columnSet(for: "category_groups", db: db)
            let groupIncome = column("is_income", fallback: "0", columns: groupColumns)
            groupJoin = "LEFT JOIN category_groups g ON g.id = c.\(categoryGroup)"
            isIncomeExpression = "COALESCE(c.\(categoryIncome), 0) = 0 AND COALESCE(g.\(groupIncome), 0) = 0"
        } else {
            groupJoin = ""
            isIncomeExpression = "COALESCE(c.\(categoryIncome), 0) = 0"
        }

        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT SUM(z.\(budgetAmount)) AS amount
                FROM zero_budgets z
                JOIN categories c ON c.id = z.\(budgetCategory)
                \(groupJoin)
                WHERE \(normalizedMonth) = ?
                  AND \(predicateForLiveRows(columns: categoryColumns, tableAlias: "c"))
                  AND \(isIncomeExpression)
                """,
            arguments: [month]
        )
        return actualAmountToMinorUnits(row?["amount"] ?? 0)
    }

    private func buildReportsDashboard(
        range: ReportDateRange,
        netWorthDays: [RawNetWorthDay],
        activityDays: [RawReportActivityDay],
        budgetedExpenses: Int
    ) -> ReportsDashboardSnapshot {
        var activityByDay: [String: ReportDailyActivity] = [:]
        for row in activityDays {
            var activity = activityByDay[row.dayID] ?? ReportDailyActivity()
            if row.categoryID == nil {
                if !row.isTransfer {
                    activity.uncategorized += row.amount
                }
            } else if row.isIncome {
                activity.income += row.amount
            } else {
                activity.expenses -= row.amount
            }
            activityByDay[row.dayID] = activity
        }

        let netWorth = buildNetWorth(range: range, rows: netWorthDays)
        let cashFlow = buildCashFlow(range: range, activityByDay: activityByDay)
        let monthComparison = buildMonthComparison(range: range, activityByDay: activityByDay)
        let budgetOverview = buildBudgetOverview(
            range: range,
            activityByDay: activityByDay,
            budgetedExpenses: budgetedExpenses
        )
        let threeMonthAverage = buildThreeMonthAverage(range: range, activityByDay: activityByDay)
        let calendar = buildTransactionCalendar(range: range, activityByDay: activityByDay)

        return ReportsDashboardSnapshot(
            range: range,
            hasData: !netWorthDays.isEmpty || !activityDays.isEmpty || budgetedExpenses != 0,
            netWorth: netWorth,
            cashFlow: cashFlow,
            monthComparison: monthComparison,
            budgetOverview: budgetOverview,
            threeMonthAverage: threeMonthAverage,
            transactionCalendar: calendar
        )
    }

    private func buildNetWorth(range: ReportDateRange, rows: [RawNetWorthDay]) -> NetWorthReport {
        let changeByDay = Dictionary(grouping: rows, by: \.dayID).mapValues { rows in
            rows.reduce(0) { $0 + $1.amount }
        }
        var balance = rows.filter { $0.dayID < range.startDay }.reduce(0) { $0 + $1.amount }
        let points = ReportCalendar.dayIDs(from: range.startDay, through: range.endDay).map { dayID in
            balance += changeByDay[dayID] ?? 0
            return ReportValuePoint(dayID: dayID, value: balance)
        }
        let first = points.first?.value ?? balance
        let latest = points.last?.value ?? balance
        return NetWorthReport(points: points, balance: latest, change: latest - first)
    }

    private func buildCashFlow(
        range: ReportDateRange,
        activityByDay: [String: ReportDailyActivity]
    ) -> CashFlowSummary {
        let activities = activityByDay
            .filter { $0.key.hasPrefix(range.anchorMonth) }
            .map(\.value)
        let income = activities.reduce(0) { $0 + $1.income }
        let expenses = activities.reduce(0) { $0 + $1.expenses }
        let uncategorized = activities.reduce(0) { $0 + $1.uncategorized }
        return CashFlowSummary(
            month: range.anchorMonth,
            income: income,
            expenses: expenses,
            net: income - expenses,
            uncategorized: uncategorized
        )
    }

    private func buildMonthComparison(
        range: ReportDateRange,
        activityByDay: [String: ReportDailyActivity]
    ) -> MonthComparisonReport {
        let comparisonMonth = ReportCalendar.shiftedMonth(range.anchorMonth, by: -1)
        let currentDay = ReportCalendar.dayNumber(from: range.endDay)
        let comparisonDays = ReportCalendar.days(in: comparisonMonth)
        var currentCumulative = 0
        var comparisonCumulative = 0
        var points: [DailyComparisonPoint] = []

        for day in 1...max(currentDay, 1) {
            currentCumulative += activityByDay[ReportCalendar.dayID(month: range.anchorMonth, day: day)]?.net ?? 0
            if day <= comparisonDays {
                comparisonCumulative += activityByDay[ReportCalendar.dayID(month: comparisonMonth, day: day)]?.net ?? 0
            }
            points.append(
                DailyComparisonPoint(
                    day: day,
                    current: currentCumulative,
                    comparison: comparisonCumulative
                )
            )
        }

        return MonthComparisonReport(
            currentMonth: range.anchorMonth,
            comparisonMonth: comparisonMonth,
            points: points,
            variance: currentCumulative - comparisonCumulative
        )
    }

    private func buildBudgetOverview(
        range: ReportDateRange,
        activityByDay: [String: ReportDailyActivity],
        budgetedExpenses: Int
    ) -> BudgetOverviewReport {
        let currentDay = max(ReportCalendar.dayNumber(from: range.endDay), 1)
        let daysInMonth = max(ReportCalendar.days(in: range.anchorMonth), 1)
        var actualCumulative = 0
        var actualPoints: [ReportValuePoint] = []
        for day in 1...currentDay {
            let dayID = ReportCalendar.dayID(month: range.anchorMonth, day: day)
            actualCumulative += activityByDay[dayID]?.expenses ?? 0
            actualPoints.append(ReportValuePoint(dayID: dayID, value: actualCumulative))
        }
        let budgetPoints = (1...daysInMonth).map { day in
            ReportValuePoint(
                dayID: ReportCalendar.dayID(month: range.anchorMonth, day: day),
                value: Int((Double(budgetedExpenses) * Double(day) / Double(daysInMonth)).rounded())
            )
        }
        return BudgetOverviewReport(
            month: range.anchorMonth,
            actualPoints: actualPoints,
            budgetPoints: budgetPoints,
            actualExpenses: actualCumulative,
            budgetedExpenses: budgetedExpenses,
            variance: actualCumulative - budgetedExpenses
        )
    }

    private func buildThreeMonthAverage(
        range: ReportDateRange,
        activityByDay: [String: ReportDailyActivity]
    ) -> ThreeMonthAverageReport {
        let historyMonths = (-3 ... -1).map { ReportCalendar.shiftedMonth(range.anchorMonth, by: $0) }
        let currentDay = max(ReportCalendar.dayNumber(from: range.endDay), 1)
        let daysInCurrentMonth = max(ReportCalendar.days(in: range.anchorMonth), 1)
        var historyCumulative = Array(repeating: 0, count: historyMonths.count)
        var currentCumulative = 0
        var currentAtComparableDay = 0
        var averageAtComparableDay = 0
        var points: [DailyComparisonPoint] = []

        for day in 1...daysInCurrentMonth {
            let current: Int?
            if day <= currentDay {
                currentCumulative += activityByDay[ReportCalendar.dayID(month: range.anchorMonth, day: day)]?.expenses ?? 0
                current = currentCumulative
                currentAtComparableDay = currentCumulative
            } else {
                current = nil
            }

            for (index, month) in historyMonths.enumerated() where day <= ReportCalendar.days(in: month) {
                historyCumulative[index] += activityByDay[ReportCalendar.dayID(month: month, day: day)]?.expenses ?? 0
            }
            let average = historyCumulative.isEmpty
                ? 0
                : Int((Double(historyCumulative.reduce(0, +)) / Double(historyCumulative.count)).rounded())
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
            variance: currentAtComparableDay - averageAtComparableDay
        )
    }

    private func buildTransactionCalendar(
        range: ReportDateRange,
        activityByDay: [String: ReportDailyActivity]
    ) -> [TransactionCalendarMonth] {
        var displayCalendar = Calendar.current
        displayCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

        return (-2 ... 0).map { offset in
            let month = ReportCalendar.shiftedMonth(range.anchorMonth, by: offset)
            let dayCount = ReportCalendar.days(in: month)
            let days = (1...max(dayCount, 1)).map { day in
                let dayID = ReportCalendar.dayID(month: month, day: day)
                let activity = dayID <= range.endDay ? activityByDay[dayID] ?? ReportDailyActivity() : ReportDailyActivity()
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
            return TransactionCalendarMonth(
                month: month,
                leadingBlankCount: leadingBlankCount,
                days: days,
                income: days.reduce(0) { $0 + $1.income },
                expenses: days.reduce(0) { $0 + $1.expenses }
            )
        }
    }
}
