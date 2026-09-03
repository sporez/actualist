import Foundation
import GRDB

extension BudgetDatabase {
    func templateEngineInputs(
        categoryTemplates: [String: [BudgetTemplateEntry]],
        monthValue: Int,
        categoryIsIncome: [String: Bool],
        previouslyBudgetedByCategory: [String: Int] = [:],
        isTrackingBudget: Bool = false,
        db: Database
    ) throws -> (
        categories: [String: BudgetTemplateEngine.Category],
        monthSources: BudgetTemplateEngine.MonthSources
    ) {
        let spentByMonth: [String: [String: Int]]
        if needsSpendingHistory(categoryTemplates) {
            spentByMonth = try categorySpendingByMonth(db: db)
        } else {
            spentByMonth = [:]
        }

        var monthSources = try templateIncomeCatalog(db: db)
        let activeSchedules = try templateActiveSchedules(db: db)
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
                        db: db
                    )
                )
            }
        )
        return (categories, monthSources)
    }

    func templateIncomeCatalog(db: Database) throws -> BudgetTemplateEngine.MonthSources {
        guard try tableExists("categories", db: db) else {
            return BudgetTemplateEngine.MonthSources()
        }
        let columns = try columnSet(for: "categories", db: db)
        let isIncome = column("is_income", fallback: "0", columns: columns)
        let name = column("name", fallback: "id", columns: columns)
        var order = [String]()
        if columns.contains("sort_order") {
            order.append("sort_order")
        }
        order.append("id")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, \(name) AS name
                FROM categories
                WHERE \(predicateForLiveRows(columns: columns))
                  AND (\(isIncome) = 1)
                ORDER BY \(order.joined(separator: ", "))
                """
        )

        var incomeCategoryIDs: Set<String> = []
        var incomeCategoryIDByLocalizedName: [String: String] = [:]
        var incomeCategoryIDsInOrder: [String] = []
        var incomeCategoryNamesByID: [String: String] = [:]
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
            let lowered = label.localizedLowercase
            if incomeCategoryIDByLocalizedName[lowered] == nil {
                incomeCategoryIDByLocalizedName[lowered] = id
            }
        }
        return BudgetTemplateEngine.MonthSources(
            incomeCategoryIDs: incomeCategoryIDs,
            incomeCategoryIDByLocalizedName: incomeCategoryIDByLocalizedName,
            incomeCategoryIDsInOrder: incomeCategoryIDsInOrder,
            incomeCategoryNamesByID: incomeCategoryNamesByID
        )
    }

    func templateActiveSchedules(db: Database) throws -> (ids: Set<String>, names: Set<String>) {
        guard try tableExists("schedules", db: db) else {
            return ([], [])
        }
        let columns = try columnSet(for: "schedules", db: db)
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
                  AND \(predicateForLiveRows(columns: columns))
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

    private func templateEngineCategory(
        categoryID: String,
        entries: [BudgetTemplateEntry],
        monthValue: Int,
        isIncome: Bool,
        previouslyBudgeted: Int,
        isTrackingBudget: Bool,
        spentByMonth: [String: [String: Int]],
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
            copiedBudgetedByLookBack[lookBack] = try categoryBudgets(
                month: monthID(sourceMonthValue),
                db: db
            )[categoryID]?.budgeted ?? 0
        }

        let needsPreviousBalance = entries.contains { entry in
            entry.type == "by"
                || entry.type == "refill"
                || entry.type == "spend"
                || entry.type == "schedule"
                || BudgetTemplateEngine.hasEffectiveLimit(entry)
        }
        let fromLastMonth: Int
        if needsPreviousBalance {
            fromLastMonth = try templateFromLastMonth(
                categoryID: categoryID,
                monthValue: monthValue,
                isIncome: isIncome,
                isTrackingBudget: isTrackingBudget,
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
                db: db
            ),
            budgetedByMonth: spendMonths.budgetedByMonth,
            leftoverByMonth: spendMonths.leftoverByMonth,
            spentByMonth: spendMonths.spentByMonthValue,
            resolvedSchedules: try resolvedSchedules(
                entries: entries,
                monthValue: monthValue,
                isIncome: isIncome,
                db: db
            ),
            previouslyBudgeted: previouslyBudgeted
        )
    }

    private func templatePercentageMonthSources(
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
            let month = monthID(sourceMonthValue)
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
            activeScheduleNames: catalog.activeScheduleNames,
            activeScheduleIDs: catalog.activeScheduleIDs
        )
    }

    private func averageActivityByMonth(
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

    private func averageFirstRelevantMonth(
        categoryID: String,
        entries: [BudgetTemplateEntry],
        spentByMonth: [String: [String: Int]],
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

        if let budgetMonth = try templateFirstBudgetMonth(categoryID: categoryID, db: db) {
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

    private func templateFirstBudgetMonth(
        categoryID: String,
        db: Database
    ) throws -> Int? {
        guard let source = try categoryBudgetSource(db: db) else {
            return nil
        }
        let categoryColumn = column("category", fallback: "NULL", columns: source.columns)
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT MIN(\(normalizedMonthExpression("month"))) AS month
                FROM \(quotedIdentifier(source.table.rawValue))
                WHERE \(categoryColumn) = ?
                  AND month IS NOT NULL
                """,
            arguments: [categoryID]
        )
        guard let raw = flexibleString(row?["month"]),
              let month = try? BudgetTemplateCalendar.parseMonth(raw) else {
            return nil
        }
        return month
    }

    private func needsSpendingHistory(
        _ categoryTemplates: [String: [BudgetTemplateEntry]]
    ) -> Bool {
        categoryTemplates.values.contains { entries in
            entries.contains {
                $0.type == "average" || $0.type == "percentage" || $0.type == "spend"
            }
        }
    }

    private func spendHistory(
        categoryID: String,
        entries: [BudgetTemplateEntry],
        monthValue: Int,
        spentByMonth: [String: [String: Int]],
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
        var cursor = earliest
        while cursor < monthValue {
            let month = monthID(cursor)
            budgetedByMonth[cursor] = try categoryBudgets(month: month, db: db)[categoryID]?.budgeted ?? 0
            spentByMonthValue[cursor] = spentByMonth[month]?[categoryID] ?? 0
            leftoverByMonth[cursor] = try envelopeCategoryValues(
                through: month,
                db: db
            )[categoryID]?.balance ?? 0
            cursor = try BudgetTemplateCalendar.shiftedMonth(cursor, by: 1)
        }
        return (budgetedByMonth, leftoverByMonth, spentByMonthValue)
    }

    private func resolvedSchedules(
        entries: [BudgetTemplateEntry],
        monthValue: Int,
        isIncome: Bool,
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
                db: db
            )
        }
        return resolved
    }

    private func resolveSchedule(
        entry: BudgetTemplateEntry,
        monthValue: Int,
        isIncome: Bool,
        db: Database
    ) throws -> BudgetTemplateEngine.ResolvedSchedule {
        let missing = entry.missingScheduleReason
        guard try tableExists("schedules", db: db), try tableExists("rules", db: db) else {
            throw LocalFirstError.unsupportedTemplate(missing)
        }
        let scheduleColumns = try columnSet(for: "schedules", db: db)
        guard scheduleColumns.contains("name") else {
            throw LocalFirstError.unsupportedTemplate(missing)
        }
        let completedColumn = scheduleColumns.contains("completed") ? "completed" : "0"
        let ruleColumn = scheduleColumns.contains("rule") ? "rule" : "NULL"
        let nameSelection = scheduleColumns.contains("name") ? "name" : "NULL"
        let identityPredicate: String
        let identityArgument: String
        if let scheduleID = entry.presentScheduleID {
            guard scheduleColumns.contains("id") else {
                throw LocalFirstError.unsupportedTemplate(missing)
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
                  AND \(predicateForLiveRows(columns: scheduleColumns))
                LIMIT 1
                """,
            arguments: [identityArgument]
        )
        guard let row else {
            throw LocalFirstError.unsupportedTemplate(missing)
        }
        let completed = flexibleBool(row["completed"])
        guard let ruleID = row["rule"] as String?, !ruleID.isEmpty else {
            throw LocalFirstError.unsupportedTemplate("schedule")
        }

        let ruleColumns = try columnSet(for: "rules", db: db)
        guard ruleColumns.contains("conditions"), ruleColumns.contains("actions") else {
            throw LocalFirstError.unsupportedTemplate("schedule")
        }
        let ruleRow = try Row.fetchOne(
            db,
            sql: """
                SELECT conditions, actions
                FROM rules
                WHERE id = ?
                  AND \(predicateForLiveRows(columns: ruleColumns))
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
                let delta = Double(try BudgetTemplateEngine(currency: try budgetCurrency(db: db))
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
            guard let next = try recurrence.nextDateString(
                onOrAfter: monthStart,
                applyWeekendSkip: true
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

    private func scheduleActionIsUnsupported(_ action: RuleAction) -> Bool {
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

    private func scheduleRuleAmount(_ condition: RuleCondition) throws -> Double {
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

    private func scheduleRecurrence(
        _ condition: RuleCondition
    ) throws -> BudgetTemplateScheduleRecurrence? {
        switch condition.value {
        case .string:
            return nil
        case .object(let object):
            if object["patterns"] != nil {
                throw LocalFirstError.unsupportedTemplate(
                    "schedule date patterns are not supported locally yet"
                )
            }
            if let endMode = object["endMode"]?.stringValue,
               endMode != "never", !endMode.isEmpty {
                throw LocalFirstError.unsupportedTemplate(
                    "schedule end dates are not supported locally yet"
                )
            }
            guard let startString = object["start"]?.stringValue,
                  let start = BudgetTemplateCalendar.validatedDate(startString),
                  let frequency = object["frequency"]?.stringValue?.lowercased(),
                  ["daily", "weekly", "monthly", "yearly"].contains(frequency) else {
                throw LocalFirstError.unsupportedTemplate("schedule")
            }
            let interval = max(Int(object["interval"]?.numberValue ?? 1), 1)
            return BudgetTemplateScheduleRecurrence(
                start: start,
                frequency: frequency,
                interval: interval,
                skipWeekend: object["skipWeekend"]?.boolValue ?? false,
                weekendSolveMode: object["weekendSolveMode"]?.stringValue ?? "after"
            )
        default:
            throw LocalFirstError.unsupportedTemplate("schedule")
        }
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

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }
}
