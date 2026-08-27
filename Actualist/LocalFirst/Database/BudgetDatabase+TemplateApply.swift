import Foundation
import GRDB

extension BudgetDatabase {
    func budgetTemplateMessages(
        command: BudgetTemplateCommand,
        month: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let monthValue = try Self.actualMonthValue(month)

        return try queue.read { db in
            let templateEngine = BudgetTemplateEngine(currency: try budgetCurrency(db: db))
            let columns = try requiredColumns(
                table: "zero_budgets",
                required: ["month", "category", "amount"],
                db: db
            )
            let canWriteGoals = columns.contains("goal")
            let goalDefsRaw = try readCategoryGoalDefsRaw(db: db)
            let categoryNames = try templateCategoryNames(db: db)
            let categoryIsIncome = try templateCategoryIsIncomeByID(db: db)
            let isTracking = try isTrackingBudget(db: db)
            let targeted = Set(
                command.categoryIDs
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            let scope: [String]
            if targeted.isEmpty {
                // Actual walks every visible category so orphan goals can clear.
                scope = try templateCategoryIDsInBudgetOrder(
                    db: db,
                    includeIncome: isTracking,
                    includeHidden: false
                )
            } else {
                // Actual applyMultipleCategoryTemplates queries `categories`
                // directly (ORDER BY sort_order, id). Do not reuse whole-budget
                // group-aware order for targeted applications.
                scope = try templateCategoryIDsInCategoryOrder(db: db)
                    .filter { targeted.contains($0) }
            }
            let force = command.mode == .overwrite || !targeted.isEmpty
            let currentBudgets = try categoryBudgets(month: monthID(monthValue), db: db)
            let existingGoals = canWriteGoals
                ? try categoryGoals(month: monthID(monthValue), db: db)
                : [:]

            var unsupported: [String] = []
            var categoryTemplates: [String: [BudgetTemplateEntry]] = [:]
            var orphanGoalCategoryIDs: [String] = []
            var availableBudget = try monthToBudget(month: monthID(monthValue), db: db)
            var incomeCatalog = try templateIncomeCatalog(db: db)
            incomeCatalog.activeScheduleNames = try templateActiveScheduleNames(db: db)
            for categoryID in scope {
                let currentBudgeted = currentBudgets[categoryID]?.budgeted ?? 0
                guard let json = goalDefsRaw[categoryID] else {
                    if existingGoals[categoryID] != nil {
                        orphanGoalCategoryIDs.append(categoryID)
                    }
                    continue
                }
                guard force || currentBudgeted == 0 else { continue }

                do {
                    if let entries = try templateEngine.decodeSupportedEntries(json: json) {
                        try templateEngine.validate(entries, for: monthValue)
                        try templateEngine.validatePercentageSources(
                            entries,
                            monthSources: incomeCatalog
                        )
                        try templateEngine.validateByScheduleAndSpend(
                            entries,
                            monthValue: monthValue,
                            activeScheduleNames: incomeCatalog.activeScheduleNames
                        )
                        categoryTemplates[categoryID] = entries
                        if !isGoalOnly(entries) {
                            availableBudget = try BudgetTemplateEngine.checkedAdd(
                                availableBudget,
                                currentBudgeted
                            )
                        }
                    }
                } catch LocalFirstError.unsupportedTemplate(let reason) {
                    unsupported.append(
                        "\(categoryNames[categoryID] ?? categoryID) (\(reason))"
                    )
                    continue
                } catch {
                    unsupported.append(
                        "\(categoryNames[categoryID] ?? categoryID) (unreadable template definition)"
                    )
                    continue
                }
            }

            guard unsupported.isEmpty else {
                throw LocalFirstError.unsupportedTemplate(
                    "categories use template types not supported yet: \(unsupported.sorted().joined(separator: ", "))"
                )
            }

            let (categories, monthSources) = try templateEngineInputs(
                categoryTemplates: categoryTemplates,
                monthValue: monthValue,
                categoryIsIncome: categoryIsIncome,
                previouslyBudgetedByCategory: currentBudgets.mapValues(\.budgeted),
                isTrackingBudget: isTracking,
                db: db
            )
            let writes = try templateEngine.computeWrites(
                categories: categories,
                orderedCategoryIDs: scope.filter { categories[$0] != nil },
                monthValue: monthValue,
                availableBudget: availableBudget,
                monthSources: monthSources
            )

            if writes.contains(where: { $0.longGoal == 1 }), !canWriteGoals {
                throw LocalFirstError.unsupportedTemplate(
                    "goal writes require zero_budgets.goal"
                )
            }

            var messages: [ActualSyncDecodedMessage] = []
            for write in writes.sorted(by: { $0.categoryID < $1.categoryID }) {
                messages += try assignCategoryBudgetMessages(
                    categoryID: write.categoryID,
                    budgeted: write.amount,
                    monthValue: monthValue,
                    columns: columns,
                    db: db,
                    builder: &builder
                )
                if canWriteGoals {
                    messages += try assignCategoryGoalMessages(
                        categoryID: write.categoryID,
                        goal: write.goal,
                        longGoal: write.longGoal,
                        monthValue: monthValue,
                        columns: columns,
                        db: db,
                        builder: &builder
                    )
                }
            }
            if canWriteGoals {
                for categoryID in orphanGoalCategoryIDs.sorted() {
                    messages += try assignCategoryGoalMessages(
                        categoryID: categoryID,
                        goal: nil,
                        longGoal: nil,
                        monthValue: monthValue,
                        columns: columns,
                        db: db,
                        builder: &builder
                    )
                }
            }
            messages += try tombstoneOrphanCleanupGroupMessages(db: db, builder: &builder)
            return messages
        }
    }

    func isTrackingBudget(db: Database) throws -> Bool {
        guard try tableExists("preferences", db: db) else {
            return false
        }
        let columns = try columnSet(for: "preferences", db: db)
        guard columns.contains("id"), columns.contains("value") else {
            return false
        }
        let budgetType = try String.fetchOne(
            db,
            sql: "SELECT value FROM preferences WHERE id = 'budgetType' LIMIT 1"
        )
        return budgetType == "tracking"
    }

    func categoryGoals(month: String, db: Database) throws -> [String: Int] {
        guard try tableExists("zero_budgets", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "zero_budgets", db: db)
        guard columns.contains("goal") else {
            return [:]
        }
        let category = column("category", fallback: "NULL", columns: columns)
        let budgetMonth = normalizedMonthExpression("month")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(category) AS category_id, goal
                FROM zero_budgets
                WHERE \(budgetMonth) = ? AND goal IS NOT NULL
                """,
            arguments: [month]
        )
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let categoryID = row["category_id"] as String? else {
                return nil
            }
            return (categoryID, actualAmountToMinorUnits(row["goal"] ?? 0))
        })
    }

    func assignCategoryGoalMessages(
        categoryID: String,
        goal: Int?,
        longGoal: Int?,
        monthValue: Int,
        columns: Set<String>,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard columns.contains("goal") else {
            return []
        }
        let existingRowID = try zeroBudgetRowID(
            monthValue: monthValue,
            categoryID: categoryID,
            columns: columns,
            db: db
        )
        let rowID = existingRowID ?? Self.zeroBudgetRowID(monthValue: monthValue, categoryID: categoryID)
        var messages: [ActualSyncDecodedMessage] = []
        messages.append(
            try builder.makeMessage(
                dataset: "zero_budgets",
                row: rowID,
                column: "month",
                value: .int(Int64(monthValue))
            )
        )
        messages.append(
            try builder.makeMessage(
                dataset: "zero_budgets",
                row: rowID,
                column: "category",
                value: .string(categoryID)
            )
        )
        if existingRowID == nil, columns.contains("carryover") {
            messages.append(
                try builder.makeMessage(
                    dataset: "zero_budgets",
                    row: rowID,
                    column: "carryover",
                    value: .bool(false)
                )
            )
        }
        messages.append(
            try builder.makeMessage(
                dataset: "zero_budgets",
                row: rowID,
                column: "goal",
                value: goal.map { .int(Int64($0)) } ?? .null
            )
        )
        if columns.contains("long_goal") {
            messages.append(
                try builder.makeMessage(
                    dataset: "zero_budgets",
                    row: rowID,
                    column: "long_goal",
                    value: longGoal.map { .int(Int64($0)) } ?? .null
                )
            )
        }
        return messages
    }

    func tombstoneOrphanCleanupGroupMessages(
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard try tableExists("cleanup_groups", db: db),
              try tableExists("categories", db: db) else {
            return []
        }
        let groupColumns = try columnSet(for: "cleanup_groups", db: db)
        let categoryColumns = try columnSet(for: "categories", db: db)
        guard groupColumns.contains("tombstone"),
              categoryColumns.contains("cleanup_def") else {
            return []
        }

        let referenced = try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT json_extract(je.value, '$.groupId') AS group_id
                FROM categories c, json_each(c.cleanup_def) je
                WHERE \(predicateForLiveRows(columns: categoryColumns, tableAlias: "c"))
                  AND c.cleanup_def IS NOT NULL
                  AND json_extract(je.value, '$.groupId') IS NOT NULL
                """
        )
        let referencedIDs = Set(referenced.filter { !$0.isEmpty })
        let liveGroups = try Row.fetchAll(
            db,
            sql: """
                SELECT id
                FROM cleanup_groups
                WHERE \(predicateForLiveRows(columns: groupColumns))
                """
        )
        return try liveGroups.compactMap { row -> ActualSyncDecodedMessage? in
            guard let id = row["id"] as String?, !referencedIDs.contains(id) else {
                return nil
            }
            return try builder.makeMessage(
                dataset: "cleanup_groups",
                row: id,
                column: "tombstone",
                value: .bool(true)
            )
        }
    }

    private func isGoalOnly(_ entries: [BudgetTemplateEntry]) -> Bool {
        !entries.contains {
            $0.directive == "template" && $0.type != "limit"
        } && entries.contains(where: \.isGoal)
    }
}
