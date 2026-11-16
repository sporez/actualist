import Foundation
import GRDB

/// One template plan's shared read of budget and spending history. The
/// budget/spending tables are read once and the month recurrence runs once
/// forward, instead of once per category, per month and per Apply mode.
/// Not `Sendable`: create it inside one database read and drop it with it.
final class TemplateHistory {
    fileprivate var inputs: BudgetCategoryValueInputs?
    fileprivate var firstBudgetMonthByCategory: [String: String]?
    fileprivate var keptRange: ClosedRange<Int>?
    fileprivate var snapshots: [Int: [String: BudgetCategoryValue]] = [:]
    /// Reads of the budget and spending tables; the work-count seam for tests.
    private(set) var inputLoadCount = 0

    fileprivate func recordInputLoad() {
        inputLoadCount += 1
    }
}

enum TemplateInputSQL {
    static func templateEngineInputs(
        categoryTemplates: [String: [BudgetTemplateEntry]],
        monthValue: Int,
        categoryIsIncome: [String: Bool],
        previouslyBudgetedByCategory: [String: Int] = [:],
        isTrackingBudget: Bool = false,
        history: TemplateHistory,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> (
        categories: [String: BudgetTemplateEngine.Category],
        monthSources: BudgetTemplateEngine.MonthSources
    ) {
        let spentByMonth: [String: [String: Int]]
        if needsSpendingHistory(categoryTemplates) {
            spentByMonth = try templateHistoryInputs(history, in: database, db: db).spentByMonth
        } else {
            spentByMonth = [:]
        }
        try primeLeftoverHistory(
            categoryTemplates: categoryTemplates,
            monthValue: monthValue,
            history: history,
            in: database,
            db: db
        )

        var monthSources = try templateIncomeCatalog(in: database, db: db)
        let activeSchedules = try templateActiveSchedules(in: database, db: db)
        monthSources.activeScheduleIDs = activeSchedules.ids
        monthSources.activeScheduleNames = activeSchedules.names
        if categoryTemplates.values.contains(where: { entries in
            entries.contains { $0.type == "percentage" }
        }) {
            monthSources = try templatePercentageMonthSources(
                catalog: monthSources,
                monthValue: monthValue,
                spentByMonth: spentByMonth
            )
        }

        let categories = try Dictionary(
            uniqueKeysWithValues: categoryTemplates.map { categoryID, entries in
                (
                    categoryID,
                    try templateEngineCategory(
                        categoryID: categoryID,
                        entries: entries,
                        monthValue: monthValue,
                        isIncome: categoryIsIncome[categoryID] ?? false,
                        previouslyBudgeted: previouslyBudgetedByCategory[categoryID] ?? 0,
                        isTrackingBudget: isTrackingBudget,
                        spentByMonth: spentByMonth,
                        history: history,
                        in: database,
                        db: db
                    )
                )
            }
        )
        return (categories, monthSources)
    }

    static func templateIncomeCatalog(in database: isolated BudgetDatabase, db: Database) throws -> BudgetTemplateEngine.MonthSources {
        guard try database.tableExists("categories", db: db) else {
            return BudgetTemplateEngine.MonthSources()
        }
        let columns = try database.columnSet(for: "categories", db: db)
        let isIncome = database.column("is_income", fallback: "0", columns: columns)
        let name = database.column("name", fallback: "id", columns: columns)
        let hidden = database.column("hidden", fallback: "0", columns: columns)
        var order = [String]()
        if columns.contains("sort_order") {
            order.append("sort_order")
        }
        order.append("id")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, \(name) AS name, \(hidden) AS hidden
                FROM categories
                WHERE \(database.predicateForLiveRows(columns: columns))
                  AND (\(isIncome) = 1)
                ORDER BY \(order.joined(separator: ", "))
                """
        )

        var incomeCategoryIDs: Set<String> = []
        var incomeCategoryIDByLocalizedName: [String: String] = [:]
        var incomeCategoryIDsInOrder: [String] = []
        var incomeCategoryNamesByID: [String: String] = [:]
        var hiddenIncomeCategoryIDs: Set<String> = []
        for row in rows {
            guard let id = row["id"] as String? else {
                continue
            }
            incomeCategoryIDs.insert(id)
            let rawName = (row["name"] as String?)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let label = rawName.flatMap { $0.isEmpty ? nil : $0 } ?? id
            incomeCategoryIDsInOrder.append(id)
            incomeCategoryNamesByID[id] = label
            if SQLiteValueCoercion.lenientBool(row["hidden"]) {
                hiddenIncomeCategoryIDs.insert(id)
            }
            let lowered = label.localizedLowercase
            if incomeCategoryIDByLocalizedName[lowered] == nil {
                incomeCategoryIDByLocalizedName[lowered] = id
            }
        }
        return BudgetTemplateEngine.MonthSources(
            incomeCategoryIDs: incomeCategoryIDs,
            incomeCategoryIDByLocalizedName: incomeCategoryIDByLocalizedName,
            incomeCategoryIDsInOrder: incomeCategoryIDsInOrder,
            incomeCategoryNamesByID: incomeCategoryNamesByID,
            hiddenIncomeCategoryIDs: hiddenIncomeCategoryIDs
        )
    }

    static func templateActiveSchedules(in database: isolated BudgetDatabase, db: Database) throws -> (ids: Set<String>, names: Set<String>) {
        guard try database.tableExists("schedules", db: db) else {
            return ([], [])
        }
        let columns = try database.columnSet(for: "schedules", db: db)
        guard columns.contains("name") else {
            return ([], [])
        }
        let idSelection = columns.contains("id") ? "id" : "NULL"
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(idSelection) AS id, name
                FROM schedules
                WHERE name IS NOT NULL
                  AND \(database.predicateForLiveRows(columns: columns))
                """
        )
        var ids: Set<String> = []
        var names: Set<String> = []
        for row in rows {
            if let id = row["id"] as String?, !id.isEmpty {
                ids.insert(id)
            }
            if let name = (row["name"] as String?)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                names.insert(name)
            }
        }
        return (ids, names)
    }

    private static func templateEngineCategory(
        categoryID: String,
        entries: [BudgetTemplateEntry],
        monthValue: Int,
        isIncome: Bool,
        previouslyBudgeted: Int,
        isTrackingBudget: Bool,
        spentByMonth: [String: [String: Int]],
        history: TemplateHistory,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> BudgetTemplateEngine.Category {
        let lookBacks = Set(
            entries.compactMap { entry in
                entry.type == "copy" ? entry.lookBack : nil
            }
        )
        var copiedBudgetedByLookBack: [Int: Int] = [:]
        for lookBack in lookBacks {
            let sourceMonthValue = try BudgetTemplateCalendar.shiftedMonth(
                monthValue,
                by: -lookBack
            )
            copiedBudgetedByLookBack[lookBack] = try templateHistoryInputs(history, in: database, db: db)
                .budgetedByMonth[YearMonth.id(packed: sourceMonthValue)]?[categoryID]?.budgeted ?? 0
        }

        let fromLastMonth: Int
        if needsPreviousBalance(entries) {
            fromLastMonth = try BudgetCategoryValueSQL.templateFromLastMonth(
                categoryID: categoryID,
                monthValue: monthValue,
                isIncome: isIncome,
                isTrackingBudget: isTrackingBudget,
                history: history,
                in: database,
                db: db
            )
        } else {
            fromLastMonth = 0
        }

        let spendMonths = try spendHistory(
            categoryID: categoryID,
            entries: entries,
            monthValue: monthValue,
            spentByMonth: spentByMonth,
            history: history,
            in: database,
            db: db
        )
        return BudgetTemplateEngine.Category(
            entries: entries,
            fromLastMonth: fromLastMonth,
            copiedBudgetedByLookBack: copiedBudgetedByLookBack,
            isIncome: isIncome,
            activityByMonth: averageActivityByMonth(
                categoryID: categoryID,
                entries: entries,
                spentByMonth: spentByMonth
            ),
            firstRelevantMonth: try averageFirstRelevantMonth(
                categoryID: categoryID,
                entries: entries,
                spentByMonth: spentByMonth,
                history: history,
                in: database,
                db: db
            ),
            budgetedByMonth: spendMonths.budgetedByMonth,
            leftoverByMonth: spendMonths.leftoverByMonth,
            spentByMonth: spendMonths.spentByMonthValue,
            resolvedSchedules: try resolvedSchedules(
                entries: entries,
                monthValue: monthValue,
                isIncome: isIncome,
                in: database,
                db: db
            ),
            previouslyBudgeted: previouslyBudgeted
        )
    }

    private static func templatePercentageMonthSources(
        catalog: BudgetTemplateEngine.MonthSources,
        monthValue: Int,
        spentByMonth: [String: [String: Int]]
    ) throws -> BudgetTemplateEngine.MonthSources {
        var totalIncomeByLookBack: [Int: Int] = [:]
        var incomeActivityByCategoryID: [String: [Int: Int]] = [:]
        for lookBack in [0, 1] {
            let sourceMonthValue = try BudgetTemplateCalendar.shiftedMonth(
                monthValue,
                by: -lookBack
            )
            let month = YearMonth.id(packed: sourceMonthValue)
            var total = 0
            for categoryID in catalog.incomeCategoryIDs {
                let activity = spentByMonth[month]?[categoryID] ?? 0
                incomeActivityByCategoryID[categoryID, default: [:]][lookBack] = activity
                total = try BudgetTemplateEngine.checkedAdd(total, activity)
            }
            totalIncomeByLookBack[lookBack] = total
        }
        return BudgetTemplateEngine.MonthSources(
            totalIncomeByLookBack: totalIncomeByLookBack,
            incomeActivityByCategoryID: incomeActivityByCategoryID,
            incomeCategoryIDs: catalog.incomeCategoryIDs,
            incomeCategoryIDByLocalizedName: catalog.incomeCategoryIDByLocalizedName,
            incomeCategoryIDsInOrder: catalog.incomeCategoryIDsInOrder,
            incomeCategoryNamesByID: catalog.incomeCategoryNamesByID,
            hiddenIncomeCategoryIDs: catalog.hiddenIncomeCategoryIDs,
            activeScheduleNames: catalog.activeScheduleNames,
            activeScheduleIDs: catalog.activeScheduleIDs
        )
    }

    private static func averageActivityByMonth(
        categoryID: String,
        entries: [BudgetTemplateEntry],
        spentByMonth: [String: [String: Int]]
    ) -> [Int: Int] {
        guard entries.contains(where: { $0.type == "average" }) else {
            return [:]
        }
        var activityByMonth: [Int: Int] = [:]
        for (monthID, byCategory) in spentByMonth {
            guard let amount = byCategory[categoryID],
                  let month = try? BudgetTemplateCalendar.parseMonth(monthID) else {
                continue
            }
            activityByMonth[month] = amount
        }
        return activityByMonth
    }

    private static func averageFirstRelevantMonth(
        categoryID: String,
        entries: [BudgetTemplateEntry],
        spentByMonth: [String: [String: Int]],
        history: TemplateHistory,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> Int? {
        guard entries.contains(where: { $0.type == "average" }) else {
            return nil
        }

        var earliest: Int?
        func consider(_ month: Int) {
            if let current = earliest {
                earliest = min(current, month)
            } else {
                earliest = month
            }
        }

        if let budgetMonth = try templateHistoryFirstBudgetMonth(history,categoryID: categoryID, in: database, db: db) {
            consider(budgetMonth)
        }
        for (monthID, byCategory) in spentByMonth {
            guard byCategory[categoryID] != nil,
                  let month = try? BudgetTemplateCalendar.parseMonth(monthID) else {
                continue
            }
            consider(month)
        }
        return earliest
    }

    private static func needsPreviousBalance(_ entries: [BudgetTemplateEntry]) -> Bool {
        entries.contains { entry in
            entry.type == "by"
                || entry.type == "refill"
                || entry.type == "spend"
                || entry.type == "schedule"
                || BudgetTemplateEngine.hasEffectiveLimit(entry)
        }
    }

    /// Runs the month recurrence once, through the month before `monthValue`,
    /// keeping every month a Spend template or the carry-in lookup will ask for.
    private static func primeLeftoverHistory(
        categoryTemplates: [String: [BudgetTemplateEntry]],
        monthValue: Int,
        history: TemplateHistory,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws {
        guard categoryTemplates.values.contains(where: needsPreviousBalance) else {
            return
        }
        let previousMonthValue = try BudgetTemplateCalendar.shiftedMonth(monthValue, by: -1)
        let earliestSpendMonth = categoryTemplates.values.joined().compactMap { entry -> Int? in
            guard entry.type == "spend", let fromMonth = entry.fromMonth else {
                return nil
            }
            return try? BudgetTemplateCalendar.parseMonth(fromMonth)
        }.min()
        _ = try templateHistoryCategoryValues(
            history,
            at: previousMonthValue,
            keepFrom: min(earliestSpendMonth ?? previousMonthValue, previousMonthValue),
            in: database,
            db: db
        )
    }

    private static func needsSpendingHistory(
        _ categoryTemplates: [String: [BudgetTemplateEntry]]
    ) -> Bool {
        categoryTemplates.values.contains { entries in
            entries.contains {
                $0.type == "average" || $0.type == "percentage" || $0.type == "spend"
            }
        }
    }

    private static func spendHistory(
        categoryID: String,
        entries: [BudgetTemplateEntry],
        monthValue: Int,
        spentByMonth: [String: [String: Int]],
        history: TemplateHistory,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> (
        budgetedByMonth: [Int: Int],
        leftoverByMonth: [Int: Int],
        spentByMonthValue: [Int: Int]
    ) {
        let fromMonths = entries.compactMap { entry -> Int? in
            guard entry.type == "spend" else {
                return nil
            }
            guard let fromMonth = entry.fromMonth else {
                return nil
            }
            return try? BudgetTemplateCalendar.parseMonth(fromMonth)
        }
        guard !fromMonths.isEmpty else {
            return ([:], [:], [:])
        }

        var budgetedByMonth: [Int: Int] = [:]
        var leftoverByMonth: [Int: Int] = [:]
        var spentByMonthValue: [Int: Int] = [:]
        let earliest = fromMonths.min() ?? monthValue
        let budgetedHistory = try templateHistoryInputs(history, in: database, db: db).budgetedByMonth
        var cursor = earliest
        while cursor < monthValue {
            let month = YearMonth.id(packed: cursor)
            budgetedByMonth[cursor] = budgetedHistory[month]?[categoryID]?.budgeted ?? 0
            spentByMonthValue[cursor] = spentByMonth[month]?[categoryID] ?? 0
            leftoverByMonth[cursor] = try templateHistoryCategoryValues(
                history,
                at: cursor,
                keepFrom: earliest,
                in: database,
                db: db
            )[categoryID]?.balance ?? 0
            cursor = try BudgetTemplateCalendar.shiftedMonth(cursor, by: 1)
        }
        return (budgetedByMonth, leftoverByMonth, spentByMonthValue)
    }

    private static func resolvedSchedules(
        entries: [BudgetTemplateEntry],
        monthValue: Int,
        isIncome: Bool,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [String: BudgetTemplateEngine.ResolvedSchedule] {
        var resolved: [String: BudgetTemplateEngine.ResolvedSchedule] = [:]
        for entry in entries where entry.type == "schedule" {
            guard let key = entry.scheduleLookupKey, resolved[key] == nil else {
                continue
            }
            resolved[key] = try resolveSchedule(
                entry: entry,
                monthValue: monthValue,
                isIncome: isIncome,
                in: database,
                db: db
            )
        }
        return resolved
    }

    private static func resolveSchedule(
        entry: BudgetTemplateEntry,
        monthValue: Int,
        isIncome: Bool,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> BudgetTemplateEngine.ResolvedSchedule {
        let missing = entry.missingScheduleError
        guard try database.tableExists("schedules", db: db), try database.tableExists("rules", db: db) else {
            throw missing
        }
        let scheduleColumns = try database.columnSet(for: "schedules", db: db)
        guard scheduleColumns.contains("name") else {
            throw missing
        }
        let completedColumn = scheduleColumns.contains("completed") ? "completed" : "0"
        let ruleColumn = scheduleColumns.contains("rule") ? "rule" : "NULL"
        let nameSelection = scheduleColumns.contains("name") ? "name" : "NULL"
        let identityPredicate: String
        let identityArgument: String
        if let scheduleID = entry.presentScheduleID {
            guard scheduleColumns.contains("id") else {
                throw missing
            }
            identityPredicate = "id = ?"
            identityArgument = scheduleID
        } else {
            identityPredicate = "TRIM(name) = ?"
            identityArgument = entry.trimmedScheduleName ?? ""
        }
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT \(nameSelection) AS name,
                       \(ruleColumn) AS rule,
                       \(completedColumn) AS completed
                FROM schedules
                WHERE \(identityPredicate)
                  AND \(database.predicateForLiveRows(columns: scheduleColumns))
                LIMIT 1
                """,
            arguments: [identityArgument]
        )
        guard let row else {
            throw missing
        }
        let completed = SQLiteValueCoercion.lenientBool(row["completed"])
        guard let ruleID = row["rule"] as String?, !ruleID.isEmpty else {
            throw LocalFirstError.unsupportedTemplate("schedule")
        }

        let ruleColumns = try database.columnSet(for: "rules", db: db)
        guard ruleColumns.contains("conditions"), ruleColumns.contains("actions") else {
            throw LocalFirstError.unsupportedTemplate("schedule")
        }
        let ruleRow = try Row.fetchOne(
            db,
            sql: """
                SELECT conditions, actions
                FROM rules
                WHERE id = ?
                  AND \(database.predicateForLiveRows(columns: ruleColumns))
                LIMIT 1
                """,
            arguments: [ruleID]
        )
        guard let ruleRow,
              let conditionsJSON = ruleRow["conditions"] as String?,
              let actionsJSON = ruleRow["actions"] as String?,
              let conditionData = conditionsJSON.data(using: .utf8),
              let actionData = actionsJSON.data(using: .utf8),
              let conditions = try? JSONDecoder().decode([RuleCondition].self, from: conditionData),
              let actions = try? JSONDecoder().decode([RuleAction].self, from: actionData) else {
            throw LocalFirstError.unsupportedTemplate("schedule")
        }
        if actions.contains(where: scheduleActionIsUnsupported) {
            throw LocalFirstError.unsupportedTemplate(
                "schedule formula and split actions are not supported locally yet"
            )
        }

        let amountCondition = conditions.first {
            ["is", "isapprox", "isbetween"].contains($0.operation) && $0.field == "amount"
        }
        let dateCondition = conditions.first {
            ["is", "isapprox"].contains($0.operation) && $0.field == "date"
        }
        guard let amountCondition, let dateCondition else {
            throw LocalFirstError.unsupportedTemplate("schedule")
        }

        var scheduleAmount = try scheduleRuleAmount(amountCondition)
        if let adjustment = entry.adjustment, let adjustmentType = entry.adjustmentType {
            switch adjustmentType {
            case "percent":
                scheduleAmount = (1 + adjustment / 100) * scheduleAmount
            case "fixed":
                let delta = Double(try BudgetTemplateEngine(currency: try BudgetCurrencySQL.budgetCurrency(in: database, db: db))
                    .amountToMinorUnits(adjustment))
                scheduleAmount += (scheduleAmount < 0 ? -1 : 1) * delta
            default:
                break
            }
        }
        let roundedAmount = try BudgetTemplateEngine.actualRound(scheduleAmount)
        let target = (isIncome ? 1 : -1) * roundedAmount
        let recurrence = try scheduleRecurrence(dateCondition)
        let monthStart = try BudgetTemplateCalendar.monthStartDate(monthValue)
        let nextDateString: String
        let isRepeating: Bool
        let frequency: String?
        let interval: Int
        if let recurrence {
            // Upstream `getNextDate` falls back to the last occurrence once an
            // ending recurrence has no occurrence left, which puts it in the past.
            guard let next = try recurrence.nextDateString(
                onOrAfter: monthStart,
                applyWeekendSkip: true,
                calendar: BudgetTemplateCalendar.gregorian
            ) ?? recurrence.lastOccurrence(
                applyWeekendAdjustment: true,
                calendar: BudgetTemplateCalendar.gregorian
            ) else {
                throw LocalFirstError.unsupportedTemplate("schedule")
            }
            nextDateString = next
            isRepeating = true
            frequency = recurrence.frequency
            interval = recurrence.interval
        } else if case .string(let date) = dateCondition.value,
                  BudgetTemplateCalendar.validatedDate(date) != nil {
            nextDateString = date
            isRepeating = false
            frequency = nil
            interval = 1
        } else {
            throw LocalFirstError.unsupportedTemplate("schedule")
        }

        let nextMonthValue = try BudgetTemplateCalendar.parseMonth(
            String(nextDateString.prefix(7))
        )
        let monthsUntil = try BudgetTemplateCalendar.monthDistance(
            from: monthValue,
            to: nextMonthValue
        )
        let resolvedName = (row["name"] as String?)
            ?? entry.name
            ?? entry.presentScheduleID
            ?? ""
        return BudgetTemplateEngine.ResolvedSchedule(
            name: resolvedName,
            amount: roundedAmount,
            nextDate: nextDateString,
            monthsUntil: monthsUntil,
            interval: interval,
            frequency: frequency,
            completed: completed,
            full: entry.full ?? false,
            isRepeating: isRepeating,
            recurrence: recurrence,
            monthlyRepeatingTarget: target
        )
    }

    private static func scheduleActionIsUnsupported(_ action: RuleAction) -> Bool {
        if action.options?["formula"] != nil {
            return true
        }
        if action.operation == "set", action.field == "amount" {
            return true
        }
        if ["split", "set-split-amount"].contains(action.operation) {
            return true
        }
        return false
    }

    private static func scheduleRuleAmount(_ condition: RuleCondition) throws -> Double {
        if condition.operation == "isbetween" {
            guard case .object(let range) = condition.value,
                  let num1 = range["num1"]?.numberValue,
                  let num2 = range["num2"]?.numberValue else {
                throw LocalFirstError.unsupportedTemplate("schedule")
            }
            return Double(try BudgetTemplateEngine.actualRound(num1 + num2)) / 2
        }
        guard let amount = condition.value.numberValue else {
            throw LocalFirstError.unsupportedTemplate("schedule")
        }
        return amount
    }

    private static func scheduleRecurrence(
        _ condition: RuleCondition
    ) throws -> ActualScheduleRecurrence? {
        switch condition.value {
        case .string:
            return nil
        case .object(let object):
            if object["patterns"] != nil {
                throw LocalFirstError.unsupportedTemplate(
                    "schedule date patterns are not supported locally yet"
                )
            }
            do {
                return try ScheduleRuleProjection.recurrence(
                    from: condition.value,
                    calendar: BudgetTemplateCalendar.gregorian
                )
            } catch {
                throw LocalFirstError.unsupportedTemplate("schedule")
            }
        default:
            throw LocalFirstError.unsupportedTemplate("schedule")
        }
    }

    private static func templateHistoryInputs(
        _ history: TemplateHistory,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> BudgetCategoryValueInputs {
        if let inputs = history.inputs {
            return inputs
        }
        let inputs = try BudgetCategoryValueSQL.categoryValueInputs(in: database, db: db)
        history.inputs = inputs
        history.recordInputLoad()
        return inputs
    }

    /// Values for `month` (Actual's `leftover` family). The first request runs
    /// the recurrence forward through `month`, keeping snapshots from
    /// `keepFrom`; later requests inside that range are lookups.
    static func templateHistoryCategoryValues(
        _ history: TemplateHistory,
        at month: Int,
        keepFrom: Int,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [String: BudgetCategoryValue] {
        let inputs = try templateHistoryInputs(history, in: database, db: db)
        if let range = history.keptRange, range.contains(month) {
            if let kept = history.snapshots[month] {
                return kept
            }
            // Precedes the first month with real data: a one-month recurrence.
            return try BudgetCategoryValueSQL.categoryValueTimeline(inputs: inputs, through: month, keepFrom: month)
                .snapshots[month] ?? [:]
        }
        let upper = max(month, history.keptRange?.upperBound ?? month)
        let lower = min(keepFrom, month, history.keptRange?.lowerBound ?? month)
        let timeline = try BudgetCategoryValueSQL.categoryValueTimeline(inputs: inputs, through: upper, keepFrom: lower)
        history.snapshots = timeline.snapshots
        history.keptRange = lower...upper
        if let kept = timeline.snapshots[month] {
            return kept
        }
        // `month` precedes the first month with real data.
        return try BudgetCategoryValueSQL.categoryValueTimeline(inputs: inputs, through: month, keepFrom: month)
            .snapshots[month] ?? [:]
    }

    /// Earliest stored budget month for a category (`MIN(month)` over its rows).
    private static func templateHistoryFirstBudgetMonth(
        _ history: TemplateHistory,
        categoryID: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> Int? {
        if history.firstBudgetMonthByCategory == nil {
            var earliest: [String: String] = [:]
            for (month, byCategory) in try templateHistoryInputs(history, in: database, db: db).budgetedByMonth {
                for categoryID in byCategory.keys {
                    if let current = earliest[categoryID], current <= month { continue }
                    earliest[categoryID] = month
                }
            }
            history.firstBudgetMonthByCategory = earliest
        }
        return history.firstBudgetMonthByCategory?[categoryID]
            .flatMap { try? BudgetTemplateCalendar.parseMonth($0) }
    }
}

private extension RuleJSONValue {
    var numberValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .string(let value):
            return Double(value)
        default:
            return nil
        }
    }
}
