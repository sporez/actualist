import Foundation
import GRDB
@testable import Actualist

/// Replays the Reports oracle contract through the production report reads: the dashboard
/// (`ReportDashboardSQL.fetchReportsDashboard`, `fetchNetWorthReport`) and the explorer
/// (`ReportExplorerSQL.fetchReportExplorer`), on a
/// starter-schema budget seeded from the fixture's world dump. The compared and excluded parts are
/// documented in `scripts/report-parity/README.md`.
///
/// Fixed clock: none of these reads consults the current date. `ReportDateRange` and
/// `ReportExplorerQuery` carry every day they read, so each case builds its ranges from the case's
/// recorded `today` (`ReportDateRange.dashboard(through:)` when the compared month is today's month).
///
/// Recorded, not compared: Actual's per-account net worth balances (`balances.<acct>`). Actual
/// computes them after aligning transfer legs across the whole account set, and Actualist has no
/// per-account net worth breakdown, so a one-account read is not the same quantity.
///
/// Mapping rules, applied to Actual's recorded values and nothing else:
/// - (a) Sign: Actualist shows spending, expenses and budget as positive where Actual has negative;
///   the replay compares `-actualist` with Actual.
/// - (b) Actual's spending `budget` is fractional; the expected value is `Math.round` of it
///   (half toward +infinity, `floor(x + 0.5)`), then rule (a) applies.
/// - (c) Spending buckets are compared one by one over the same 28 buckets Actual folds into.
/// - (d) After today Actual has null. A bucket Actualist does not produce is null; a number where
///   Actual has null stays a mismatch.
@MainActor
enum ReportOracleReplay {
    private typealias Value = OracleValue

    /// Cleared before seeding, children before parents.
    private static let clearedTables = [
        "transactions", "schedules_next_date", "schedules", "rules", "payee_mapping", "payees",
        "zero_budgets", "reflect_budgets", "zero_budget_months", "reflect_budget_months",
        "category_mapping", "categories", "category_groups", "accounts", "account_groups", "preferences",
        "dashboard",
    ]
    private static let seedTables = [
        "accounts", "payees", "payee_mapping", "category_groups", "categories", "category_mapping",
        "transactions", "zero_budgets", "reflect_budgets", "preferences",
    ]

    // MARK: Small value helpers

    private static func number(_ value: Int) -> Value { .number(Double(value)) }
    /// Rule (a): the Actual-signed form of an Actualist amount.
    private static func negated(_ value: Int) -> Value { .number(-Double(value)) }
    private static func negated(_ value: Int?) -> Value { value.map(negated) ?? .null }
    private static func list(_ values: [Value]) -> Value { .array(values) }
    private static func double(_ value: Any?, _ name: String) throws -> Double {
        guard let result = OracleJSON.double(value) else {
            throw OracleReplayError.malformedFixture("\(name) is not a number")
        }
        return result
    }
    private static func nullableDouble(_ value: Any?) -> Value {
        guard let value, !(value is NSNull), let result = OracleJSON.double(value) else { return .null }
        return .number(result)
    }
    private static func monthEnd(_ month: String) -> String {
        ReportCalendar.dayID(month: month, day: ReportCalendar.days(in: month))
    }
    private static func monthStart(_ month: String) -> String {
        ReportCalendar.dayID(month: month, day: 1)
    }

    // MARK: Expected

    /// What Actual recorded for the case, in comparison form.
    static func expected(_ entry: [String: Any]) throws -> OracleValue {
        let kind = try OracleJSON.string(entry, "kind")
        let input = try OracleJSON.object(entry["input"], "input")
        let recorded = try OracleJSON.object(entry["expected"], "expected")
        switch kind {
        case "net-worth": return try expectedNetWorth(input: input, recorded: recorded)
        case "cash-flow": return try expectedCashFlow(input: input, recorded: recorded)
        case "spending": return try expectedSpending(input: input, recorded: recorded)
        case "calendar": return try expectedCalendar(recorded: recorded)
        default: throw OracleReplayError.malformedFixture("unknown case kind \(kind)")
        }
    }

    private static func expectedNetWorth(input: [String: Any], recorded: [String: Any]) throws -> Value {
        let points = try OracleJSON.objects(recorded["points"], "points")
        let explorerPoints = try points.map { point -> Value in
            .object([
                "period": .string(try OracleJSON.string(point, "period")),
                "y": .number(try double(point["y"], "y")),
            ])
        }
        var fields: [String: Value] = [
            "explorer": .object([
                "points": list(explorerPoints),
                "netWorth": .number(try double(recorded["netWorth"], "netWorth")),
            ]),
        ]
        if dashboardNetWorthApplies(input) {
            fields["dashboard"] = .object([
                "points": list(try points.map { point in
                    .object([
                        "period": .string(try OracleJSON.string(point, "period")),
                        "y": .number(try double(point["y"], "y")),
                    ])
                }),
                "netWorth": .number(try double(recorded["netWorth"], "netWorth")),
                "totalChange": .number(try double(recorded["totalChange"], "totalChange")),
            ])
        }
        return .object(fields)
    }

    /// The dashboard's net worth card counts every live account at month granularity.
    private static func dashboardNetWorthApplies(_ input: [String: Any]) -> Bool {
        (input["interval"] as? String) == "Monthly" && (input["accountSet"] as? String) == "ui"
    }

    private static func expectedCashFlow(input: [String: Any], recorded: [String: Any]) throws -> Value {
        let periods = try OracleJSON.objects(recorded["periods"], "periods")
        var fields: [String: Value] = [
            "explorer": .object([
                "periods": list(try periods.map { period in
                    .object([
                        "period": .string(try OracleJSON.string(period, "period")),
                        "income": .number(try double(period["income"], "income")),
                        "expenses": .number(try double(period["expenses"], "expenses")),
                    ])
                }),
                "totalIncome": .number(try double(recorded["totalIncome"], "totalIncome")),
                "totalExpenses": .number(try double(recorded["totalExpenses"], "totalExpenses")),
            ]),
        ]
        if dashboardCashFlowApplies(input), let last = periods.last {
            fields["dashboard"] = .object([
                "income": .number(try double(last["income"], "income")),
                "expenses": .number(try double(last["expenses"], "expenses")),
            ])
        }
        return .object(fields)
    }

    /// The dashboard card is the anchor month of an unfiltered monthly cash flow.
    private static func dashboardCashFlowApplies(_ input: [String: Any]) -> Bool {
        (input["concise"] as? Bool) == true && ((input["conditions"] as? [Any])?.isEmpty ?? true)
    }

    private static func expectedSpending(input: [String: Any], recorded: [String: Any]) throws -> Value {
        let rows = try OracleJSON.objects(recorded["intervalData"], "intervalData").sorted {
            (OracleJSON.int($0["day"]) ?? 0) < (OracleJSON.int($1["day"]) ?? 0)
        }
        let compare = list(rows.map { nullableDouble($0["compare"]) })
        let average = list(try rows.map { .number(try double($0["average"], "average")) })
        // Rule (b): Math.round, half toward +infinity.
        let budget = list(try rows.map { .number((try double($0["budget"], "budget") + 0.5).rounded(.down)) })
        var fields: [String: Value] = [
            "explorer": .object([
                "compare": compare,
                "average": average,
                "budget": budget,
                "totalTotals": .number(try double(recorded["totalTotals"], "totalTotals")),
            ]),
        ]
        if (input["conditions"] as? [Any])?.isEmpty ?? true {
            fields["dashboard"] = .object([
                "compare": compare,
                "compareTo": list(try rows.map { .number(try double($0["compareTo"], "compareTo")) }),
                "budgetActual": compare,
                "average": average,
                "averageCurrent": compare,
                "budget": budget,
            ])
        }
        return .object(fields)
    }

    private static func expectedCalendar(recorded: [String: Any]) throws -> Value {
        var months: [Value] = []
        var exploredDays: [Value] = []
        for month in try OracleJSON.objects(recorded["months"], "months") {
            let monthID = String(try OracleJSON.string(month, "start").prefix(7))
            let data = try OracleJSON.objects(month["data"], "data")
            let inMonth = try data.filter { try OracleJSON.string($0, "date").hasPrefix(monthID) }
            let leading = try data.firstIndex { try OracleJSON.string($0, "date").hasPrefix(monthID) } ?? 0
            let days = try inMonth.map { day -> Value in
                .object([
                    "dayID": .string(try OracleJSON.string(day, "date")),
                    "income": .number(try double(day["incomeValue"], "incomeValue")),
                    "expenses": .number(try double(day["expenseValue"], "expenseValue")),
                ])
            }
            exploredDays += days
            months.append(.object([
                "month": .string(monthID),
                "leadingBlankCount": number(leading),
                "income": .number(try double(month["totalIncome"], "totalIncome")),
                "expenses": .number(try double(month["totalExpense"], "totalExpense")),
                "days": list(days),
            ]))
        }
        return .object([
            "dashboard": .object(["months": list(months)]),
            "explorer": .object(["days": list(exploredDays)]),
        ])
    }

    // MARK: Replay

    static func replay(entry: [String: Any], worlds: [String: Any]) async throws -> OracleValue {
        let permit = await OracleReplayGate.shared.acquire()
        defer { permit.release() }
        let kind = try OracleJSON.string(entry, "kind")
        let input = try OracleJSON.object(entry["input"], "input")
        let recorded = try OracleJSON.object(entry["expected"], "expected")
        let today = try OracleJSON.string(entry, "today")
        let worldName = try OracleJSON.string(entry, "world")

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ReportOracleReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await OracleReplayDatabase.starter(
            at: directory.appending(path: "db.sqlite"),
            localNodeID: "node1"
        )
        try await seed(
            database,
            world: OracleJSON.object(worlds[worldName], "world \(worldName)"),
            input: input,
            kind: kind
        )

        switch kind {
        case "net-worth":
            return try await replayNetWorth(database, input: input, recorded: recorded)
        case "cash-flow":
            return try await replayCashFlow(database, input: input, today: today)
        case "spending":
            return try await replaySpending(database, input: input, recorded: recorded, today: today)
        case "calendar":
            return try await replayCalendar(database, input: input)
        default:
            throw OracleReplayError.malformedFixture("unknown case kind \(kind)")
        }
    }

    private static func explorer(
        _ database: BudgetDatabase,
        metric: ReportExplorerMetric,
        startDay: String,
        endDay: String,
        interval: ReportInterval,
        filters: ReportExplorerFilters
    ) async throws -> ReportExplorerSnapshot {
        try await ReportExplorerSQL.fetchReportExplorer(query: ReportExplorerQuery(
            metric: metric,
            startDay: startDay,
            endDay: endDay,
            interval: interval,
            filters: filters
        ), in: database)
    }

    private static func periodKey(_ point: ReportExplorerPoint, interval: ReportInterval) -> String {
        interval == .month ? String(point.period.startDay.prefix(7)) : point.period.startDay
    }

    // MARK: Net worth

    private static func replayNetWorth(
        _ database: BudgetDatabase,
        input: [String: Any],
        recorded: [String: Any]
    ) async throws -> Value {
        let interval: ReportInterval = (input["interval"] as? String) == "Daily" ? .day : .month
        let startDay = try OracleJSON.string(recorded, "start")
        let endDay = try OracleJSON.string(recorded, "end")
        let accountIDs = (recorded["accountIDs"] as? [String]) ?? []
        let accountSet = try OracleJSON.string(input, "accountSet")

        var filters = ReportExplorerFilters.defaults(for: .netWorth)
        switch accountSet {
        case "open":
            filters.accounts = .only(Set(accountIDs))
        case "onbudget":
            filters.includesOffBudget = false
        default:
            break
        }
        let all = try await explorer(
            database, metric: .netWorth, startDay: startDay, endDay: endDay, interval: interval, filters: filters
        )
        let points = all.points.map { point -> Value in
            .object([
                "period": .string(periodKey(point, interval: interval)),
                "y": number(point.endingBalance),
            ])
        }
        var fields: [String: Value] = [
            "explorer": .object(["points": list(points), "netWorth": number(all.totals.endingBalance)]),
        ]
        if dashboardNetWorthApplies(input) {
            let startMonth = try OracleJSON.string(input, "start")
            let endMonth = try OracleJSON.string(input, "end")
            let range = ReportDateRange(
                anchorMonth: endMonth,
                startDay: monthStart(startMonth),
                endDay: monthEnd(endMonth)
            )
            let report = try await ReportDashboardSQL.fetchNetWorthReport(range: range, in: database)
            fields["dashboard"] = .object([
                "points": list(report.points.map { point in
                    .object(["period": .string(String(point.dayID.prefix(7))), "y": number(point.value)])
                }),
                "netWorth": number(report.balance),
                "totalChange": number(report.change),
            ])
        }
        return .object(fields)
    }

    // MARK: Cash flow

    private static func replayCashFlow(
        _ database: BudgetDatabase,
        input: [String: Any],
        today: String
    ) async throws -> Value {
        let concise = (input["concise"] as? Bool) == true
        let interval: ReportInterval = concise ? .month : .day
        let startMonth = try OracleJSON.string(input, "start")
        let endMonth = try OracleJSON.string(input, "end")
        let endDay = min(monthEnd(endMonth), today)
        var filters = ReportExplorerFilters.defaults(for: .cashFlow)
        if let id = accountCondition(input) {
            filters.accounts = .only([id])
        }
        let snapshot = try await explorer(
            database,
            metric: .cashFlow,
            startDay: monthStart(startMonth),
            endDay: endDay,
            interval: interval,
            filters: filters
        )
        var fields: [String: Value] = [
            "explorer": .object([
                "periods": list(snapshot.points.map { point in
                    .object([
                        "period": .string(periodKey(point, interval: interval)),
                        "income": number(point.income),
                        "expenses": negated(point.expenses),
                    ])
                }),
                "totalIncome": number(snapshot.totals.income),
                "totalExpenses": negated(snapshot.totals.expenses),
            ]),
        ]
        if dashboardCashFlowApplies(input) {
            let range = ReportDateRange(
                anchorMonth: endMonth,
                startDay: monthStart(ReportCalendar.shiftedMonth(endMonth, by: -5)),
                endDay: endDay
            )
            let dashboard = try await ReportDashboardSQL.fetchReportsDashboard(range: range, in: database)
            fields["dashboard"] = .object([
                "income": number(dashboard.cashFlow.income),
                "expenses": negated(dashboard.cashFlow.expenses),
            ])
        }
        return .object(fields)
    }

    /// The account of an `account is X` condition, which the explorer states as an account filter.
    private static func accountCondition(_ input: [String: Any]) -> String? {
        conditionValue(input, field: "account")
    }

    private static func conditionValue(_ input: [String: Any], field: String) -> String? {
        for condition in (input["conditions"] as? [[String: Any]]) ?? []
        where condition["field"] as? String == field && condition["op"] as? String == "is" {
            return condition["value"] as? String
        }
        return nil
    }

    // MARK: Spending

    private static func replaySpending(
        _ database: BudgetDatabase,
        input: [String: Any],
        recorded: [String: Any],
        today: String
    ) async throws -> Value {
        let compare = try OracleJSON.string(input, "compare")
        let toDate = min(monthEnd(compare), today)
        let fullMonth = monthEnd(compare)
        var filters = ReportExplorerFilters.defaults(for: .spending)
        if let id = accountCondition(input) {
            filters.accounts = .only([id])
        }
        if let id = conditionValue(input, field: "category") {
            // A category condition excludes uncategorized rows, as Actual's filter does.
            filters.categories = .only([id])
            filters.includesUncategorized = false
        }
        func bucketed<T>(_ values: [T], missing: T) -> [T] {
            (0..<28).map { $0 < values.count ? values[$0] : missing }
        }

        let current = try await explorer(
            database, metric: .spendingAverage, startDay: monthStart(compare), endDay: toDate,
            interval: .day, filters: filters
        )
        let history = try await explorer(
            database, metric: .spendingAverage, startDay: monthStart(compare), endDay: fullMonth,
            interval: .day, filters: filters
        )
        let budget = try await explorer(
            database, metric: .budgetOverview, startDay: monthStart(compare), endDay: fullMonth,
            interval: .day, filters: filters
        )
        let totals = try await explorer(
            database,
            metric: .spending,
            startDay: try OracleJSON.string(recorded, "startDate"),
            endDay: try OracleJSON.string(recorded, "endDate"),
            interval: .month,
            filters: filters
        )
        var fields: [String: Value] = [
            "explorer": .object([
                "compare": list(bucketed(current.points.map { negated($0.expenses) }, missing: .null)),
                "average": list(bucketed(history.points.map { negated($0.comparison) }, missing: .null)),
                "budget": list(bucketed(budget.points.map { negated($0.budgeted) }, missing: .null)),
                "totalTotals": negated(totals.totals.expenses),
            ]),
        ]
        if (input["conditions"] as? [Any])?.isEmpty ?? true {
            let range = dashboardRange(compare: compare, endDay: toDate, today: today)
            let dashboard = try await ReportDashboardSQL.fetchReportsDashboard(range: range, in: database)
            let comparison = dashboard.monthComparison.points
            let overview = dashboard.budgetOverview
            let average = dashboard.threeMonthAverage.points
            fields["dashboard"] = .object([
                "compare": list(bucketed(comparison.map { negated($0.current) }, missing: .null)),
                "compareTo": list(bucketed(comparison.map { negated($0.comparison) }, missing: .null)),
                "budgetActual": list(bucketed(overview.actualPoints.map { negated($0.value) }, missing: .null)),
                "average": list(bucketed(average.map { negated($0.comparison) }, missing: .null)),
                "averageCurrent": list(bucketed(average.map { negated($0.current) }, missing: .null)),
                "budget": list(bucketed(overview.budgetPoints.map { negated($0.value) }, missing: .null)),
            ])
        }
        return .object(fields)
    }

    /// The six-month dashboard range ending at the compared month. In today's month the production
    /// builder makes it from the case's fixed date.
    private static func dashboardRange(compare: String, endDay: String, today: String) -> ReportDateRange {
        if String(today.prefix(7)) == compare, let date = ReportCalendar.date(fromDayID: today) {
            return ReportDateRange.dashboard(through: date, calendar: ReportCalendar.gregorianUTC)
        }
        return ReportDateRange(
            anchorMonth: compare,
            startDay: monthStart(ReportCalendar.shiftedMonth(compare, by: -5)),
            endDay: endDay
        )
    }

    // MARK: Calendar

    private static func replayCalendar(_ database: BudgetDatabase, input: [String: Any]) async throws -> Value {
        let startMonth = try OracleJSON.string(input, "start")
        let endMonth = try OracleJSON.string(input, "end")
        let range = ReportDateRange(
            anchorMonth: endMonth,
            startDay: monthStart(ReportCalendar.shiftedMonth(endMonth, by: -5)),
            endDay: monthEnd(endMonth)
        )
        let dashboard = try await ReportDashboardSQL.fetchReportsDashboard(range: range, in: database)
        // The calendar card's filters, as the card opens its detail (transfer rule: the link).
        let filters = ReportCardKind.transactionCalendar.explorerDefaultFilters(
            calendarTransfers: dashboard.calendarTransfers
        )
        let snapshot = try await explorer(
            database,
            metric: .cashFlow,
            startDay: monthStart(startMonth),
            endDay: monthEnd(endMonth),
            interval: .day,
            filters: filters
        )
        let months: [Value] = dashboard.transactionCalendar.map(calendarMonthValue)
        let days: [Value] = snapshot.points.map(calendarExplorerDayValue)
        return .object([
            "dashboard": .object(["months": list(months)]),
            "explorer": .object(["days": list(days)]),
        ])
    }

    private static func calendarMonthValue(_ month: TransactionCalendarMonth) -> Value {
        let days: [Value] = month.days.map { day in
            let fields: [String: Value] = [
                "dayID": .string(day.dayID),
                "income": number(day.income),
                "expenses": number(day.expenses),
            ]
            return .object(fields)
        }
        let fields: [String: Value] = [
            "month": .string(month.month),
            "leadingBlankCount": number(month.leadingBlankCount),
            "income": number(month.income),
            "expenses": number(month.expenses),
            "days": list(days),
        ]
        return .object(fields)
    }

    private static func calendarExplorerDayValue(_ point: ReportExplorerPoint) -> Value {
        let fields: [String: Value] = [
            "dayID": .string(point.period.startDay),
            "income": number(point.income),
            "expenses": number(point.expenses),
        ]
        return .object(fields)
    }

    // MARK: Seeding

    private struct SeedRow: Sendable {
        let sql: String
        let values: [DatabaseValue]
    }

    private static func insertion(_ table: String, _ row: [String: Any]) throws -> SeedRow {
        let columns = row.keys.sorted()
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        return SeedRow(
            sql: "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))",
            values: try columns.map { try OracleWriteReplay.seedValue(row[$0] ?? NSNull(), column: "\(table).\($0)") }
        )
    }

    /// The world's rows, then what the case itself sets: the first-weekday preference, and a calendar
    /// card whose conditions are the case's (Actual passes them straight to the spreadsheet).
    private static func seed(
        _ database: BudgetDatabase,
        world: [String: Any],
        input: [String: Any],
        kind: String
    ) async throws {
        var rows: [SeedRow] = []
        for table in seedTables {
            for row in try OracleJSON.objects(world[table] ?? [], table) {
                rows.append(try insertion(table, row))
            }
        }
        if let first = input["firstDayOfWeekIdx"] as? String {
            rows.append(try insertion("preferences", ["id": "firstDayOfWeekIdx", "value": first]))
        }
        if kind == "calendar", let conditions = input["conditions"] as? [Any], !conditions.isEmpty {
            let meta = try JSONSerialization.data(withJSONObject: ["conditions": conditions])
            rows.append(try insertion("dashboard", [
                "id": "calendar-card-1",
                "type": "calendar-card",
                "width": 8,
                "height": 4,
                "x": 0,
                "y": 0,
                "meta": String(decoding: meta, as: UTF8.self),
                "tombstone": 0,
            ]))
        }
        let insertions = rows
        let queue = await database.queue
        let cleared = clearedTables
        try await queue.write { db in
            for table in cleared {
                guard try db.tableExists(table) else { continue }
                try db.execute(sql: "DELETE FROM \(table)")
            }
            for row in insertions {
                try db.execute(sql: row.sql, arguments: StatementArguments(row.values as [any DatabaseValueConvertible]))
            }
        }
    }

    /// The fixture's top-level `worlds`: the rows each budget type starts from.
    static func worlds(domain: String, fileName: String) throws -> [String: Any] {
        let url = try ParityOraclePin.fixtureURL(domain).appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OracleReplayError.missingFixture(url.path)
        }
        let root = try OracleJSON.object(OracleJSONFileCache.jsonObject(at: url), fileName)
        return try OracleJSON.object(root["worlds"], "worlds")
    }
}
