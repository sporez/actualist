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
    let isInflow: Bool
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

        var transferPredicates: [String] = []
        var payeeJoin = ""
        if try tableExists("payees", db: db),
           let payeeColumn = ["description", "payee"].first(where: transactionColumns.contains) {
            let payeeColumns = try columnSet(for: "payees", db: db)
            if let transferAccount = ["transfer_acct", "transfer_account"].first(where: payeeColumns.contains) {
                if try tableExists("payee_mapping", db: db) {
                    let mappingColumns = try columnSet(for: "payee_mapping", db: db)
                    if let targetID = ["targetId", "target_id"].first(where: mappingColumns.contains) {
                        payeeJoin = """
                            LEFT JOIN payee_mapping pm ON pm.id = t.\(payeeColumn)
                            LEFT JOIN payees py ON py.id = COALESCE(pm.\(targetID), t.\(payeeColumn))
                            """
                    } else {
                        payeeJoin = "LEFT JOIN payees py ON py.id = t.\(payeeColumn)"
                    }
                } else {
                    payeeJoin = "LEFT JOIN payees py ON py.id = t.\(payeeColumn)"
                }
                transferPredicates.append("(py.\(transferAccount) IS NOT NULL AND py.\(transferAccount) != '')")
            }
        }
        let isTransferExpression = transferPredicates.isEmpty
            ? "0"
            : "CASE WHEN \(transferPredicates.joined(separator: " OR ")) THEN 1 ELSE 0 END"
        let isInflowExpression = "CASE WHEN t.\(amount) > 0 THEN 1 ELSE 0 END"

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(normalizedDate) AS day,
                       \(mappedCategory) AS category_id,
                       \(isIncomeExpression) AS is_income,
                       \(isTransferExpression) AS is_transfer,
                       \(isInflowExpression) AS is_inflow,
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
                GROUP BY \(normalizedDate), \(mappedCategory), \(isIncomeExpression), \(isTransferExpression), \(isInflowExpression)
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
                isInflow: flexibleBool(row["is_inflow"]),
                amount: actualAmountToMinorUnits(row["amount"] ?? 0)
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
        let isInflowExpression = "CASE WHEN t.\(amount) > 0 THEN 1 ELSE 0 END"
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
                       SUM(t.\(amount)) AS amount
                FROM transactions t
                JOIN accounts a ON a.id = t.\(account)
                LEFT JOIN transactions parent ON parent.id = t.\(parentID)
                WHERE \(predicateForLiveRows(columns: transactionColumns, tableAlias: "t"))
                  AND \(predicateForLiveRows(columns: accountColumns, tableAlias: "a"))
                  AND (t.\(parentID) IS NULL OR \(predicateForLiveRows(columns: transactionColumns, tableAlias: "parent")))
                  AND (t.\(isParent) = 0 OR t.\(isParent) IS NULL)
                  AND t.\(date) IS NOT NULL
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
                amount: actualAmountToMinorUnits(row["amount"] ?? 0)
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

    private func reportBudgetedExpenses(month: String, db: Database) throws -> Int {
        var budgetTable = "zero_budgets"
        if try tableExists("preferences", db: db), try tableExists("reflect_budgets", db: db) {
            let preferenceColumns = try columnSet(for: "preferences", db: db)
            if preferenceColumns.contains("id"), preferenceColumns.contains("value") {
                let budgetType = try String.fetchOne(
                    db,
                    sql: "SELECT value FROM preferences WHERE id = 'budgetType' LIMIT 1"
                )
                if budgetType == "tracking" {
                    budgetTable = "reflect_budgets"
                }
            }
        }
        guard try tableExists(budgetTable, db: db) else { return 0 }

        let budgetColumns = try columnSet(for: budgetTable, db: db)
        let budgetAmount = column("amount", fallback: "0", columns: budgetColumns)
        let budgetMonth = column("month", fallback: "NULL", columns: budgetColumns)
        let normalizedMonth = normalizedMonthExpression("z.\(budgetMonth)")

        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT SUM(z.\(budgetAmount)) AS amount
                FROM \(budgetTable) z
                WHERE \(normalizedMonth) = ?
                """,
            arguments: [month]
        )
        return actualAmountToMinorUnits(row?["amount"] ?? 0)
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
                activity.spending = try reportSubtract(activity.spending, row.amount)
            }
            if row.categoryID == nil {
                if !row.isTransfer {
                    activity.uncategorized = try reportAdd(activity.uncategorized, row.amount)
                }
            }
            if !row.isTransfer, row.isInflow {
                activity.income = try reportAdd(activity.income, row.amount)
            } else if !row.isTransfer, row.amount < 0 {
                activity.expenses = try reportSubtract(activity.expenses, row.amount)
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
            changeByMonth[month] = try reportSum(monthRows.map(\.amount))
        }
        var balance = try reportSum(rows.filter { $0.dayID < pointStartDay }.map(\.amount))
        var points: [ReportValuePoint] = []
        for month in ReportCalendar.monthIDs(from: pointStartMonth, through: range.anchorMonth) {
            balance = try reportAdd(balance, changeByMonth[month] ?? 0)
            points.append(
                ReportValuePoint(dayID: ReportCalendar.dayID(month: month, day: 1), value: balance)
            )
        }
        let first = points.first?.value ?? balance
        let latest = points.last?.value ?? balance
        return NetWorthReport(
            points: points,
            balance: latest,
            change: try reportSubtract(latest, first)
        )
    }

    private func buildCashFlow(
        range: ReportDateRange,
        activityByDay: [String: ReportDailyActivity]
    ) throws -> CashFlowSummary {
        let activities = activityByDay
            .filter { $0.key.hasPrefix(range.anchorMonth) && $0.key <= range.endDay }
            .map(\.value)
        let income = try reportSum(activities.map(\.income))
        let expenses = try reportSum(activities.map(\.expenses))
        let uncategorized = try reportSum(activities.map(\.uncategorized))
        return CashFlowSummary(
            month: range.anchorMonth,
            income: income,
            expenses: expenses,
            net: try reportSubtract(income, expenses),
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
                currentCumulative = try reportAdd(currentCumulative, spending(
                    in: range.anchorMonth,
                    dayBucket: day,
                    activityByDay: activityByDay
                ))
                current = currentCumulative
                currentAtComparableDay = currentCumulative
            } else {
                current = nil
            }

            comparisonCumulative = try reportAdd(comparisonCumulative, spending(
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
            variance: try reportSubtract(currentAtComparableDay, comparisonAtComparableDay)
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
            actualCumulative = try reportAdd(actualCumulative, spending(
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
                value: try reportScaled(
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
            variance: try reportSubtract(actualCumulative, budgetedToDate)
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
                currentCumulative = try reportAdd(currentCumulative, spending(
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
                historyCumulative[index] = try reportAdd(historyCumulative[index], spending(
                    in: month,
                    dayBucket: day,
                    activityByDay: activityByDay
                ))
            }
            let average = historyCumulative.isEmpty
                ? 0
                : try reportScaled(
                    reportSum(historyCumulative),
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
            variance: try reportSubtract(currentAtComparableDay, averageAtComparableDay)
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
            result = try reportAdd(
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
                activity.income = try reportAdd(activity.income, row.amount)
            } else if row.amount < 0 {
                activity.expenses = try reportSubtract(activity.expenses, row.amount)
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
                income: try reportSum(days.map(\.income)),
                expenses: try reportSum(days.map(\.expenses))
            ))
        }
        return months
    }
}

private func reportAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow else {
        throw LocalFirstError.numericValueOutOfRange
    }
    return result.partialValue
}

private func reportSubtract(_ lhs: Int, _ rhs: Int) throws -> Int {
    let result = lhs.subtractingReportingOverflow(rhs)
    guard !result.overflow else {
        throw LocalFirstError.numericValueOutOfRange
    }
    return result.partialValue
}

private func reportSum<S: Sequence>(_ values: S) throws -> Int where S.Element == Int {
    var total = 0
    for value in values {
        total = try reportAdd(total, value)
    }
    return total
}

private func reportScaled(_ value: Int, multiplier: Int, divisor: Int) throws -> Int {
    guard divisor > 0 else {
        throw LocalFirstError.numericValueOutOfRange
    }
    let multiplied = value.multipliedReportingOverflow(by: multiplier)
    guard !multiplied.overflow else {
        throw LocalFirstError.numericValueOutOfRange
    }

    let quotient = multiplied.partialValue / divisor
    let remainder = multiplied.partialValue % divisor
    let doubledRemainder = remainder.multipliedReportingOverflow(by: 2)
    guard !doubledRemainder.overflow else {
        throw LocalFirstError.numericValueOutOfRange
    }
    guard doubledRemainder.partialValue.magnitude >= divisor.magnitude else {
        return quotient
    }
    return try reportAdd(quotient, multiplied.partialValue >= 0 ? 1 : -1)
}
