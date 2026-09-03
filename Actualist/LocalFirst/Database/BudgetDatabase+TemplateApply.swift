import Foundation
import GRDB

/// The template engine's output for one apply: the CRDT messages plus the
/// per-category resulting assignment, which the History action log pairs with
/// live before-values to record a `template` gesture. Categories whose rows
/// only cleared orphan goals or tombstoned cleanup groups appear in messages
/// but not in `assignments`.
struct BudgetTemplateApplyResult: Sendable {
    var messages: [ActualSyncDecodedMessage]
    var assignments: [BudgetTemplateAssignment]
}

extension BudgetDatabase {
    func budgetTemplateMessages(
        command: BudgetTemplateCommand,
        month: String,
        currentMonth: String? = nil,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try budgetTemplateApply(
            command: command,
            month: month,
            currentMonth: currentMonth,
            builder: &builder
        ).messages
    }

    func budgetTemplateApply(
        command: BudgetTemplateCommand,
        month: String,
        currentMonth: String? = nil,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> BudgetTemplateApplyResult {
        return try queue.read { db in
            let prepared = try budgetTemplatePlan(
                command: command,
                month: month,
                currentMonth: currentMonth,
                skipAvailableClamp: false,
                goalDefOverrides: [:],
                skipStaleCheck: false,
                db: db
            )
            let writes = prepared.compute.writes
            let table = prepared.table
            let columns = prepared.columns
            let canWriteGoals = prepared.canWriteGoals
            let orphanGoalCategoryIDs = prepared.orphanGoalCategoryIDs
            let monthValue = try Self.actualMonthValue(month)

            var messages: [ActualSyncDecodedMessage] = []
            for write in writes.sorted(by: { $0.categoryID < $1.categoryID }) {
                messages += try assignCategoryBudgetMessages(
                    categoryID: write.categoryID,
                    budgeted: write.amount,
                    monthValue: monthValue,
                    table: table,
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
                        table: table,
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
                        table: table,
                        columns: columns,
                        db: db,
                        builder: &builder
                    )
                }
            }
            messages += try tombstoneOrphanCleanupGroupMessages(db: db, builder: &builder)
            return BudgetTemplateApplyResult(
                messages: messages,
                assignments: writes.map {
                    BudgetTemplateAssignment(categoryID: $0.categoryID, amount: $0.amount)
                }
            )
        }
    }

    func categoryGoals(month: String, db: Database) throws -> [String: Int] {
        guard let source = try categoryBudgetSource(db: db) else {
            return [:]
        }
        guard source.columns.contains("goal") else {
            return [:]
        }
        let category = column("category", fallback: "NULL", columns: source.columns)
        let budgetMonth = normalizedMonthExpression("month")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(category) AS category_id, goal
                FROM \(quotedIdentifier(source.table.rawValue))
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
        table: BudgetTable,
        columns: Set<String>,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard columns.contains("goal") else {
            return []
        }
        let existingRowID = try budgetRowID(
            table: table,
            monthValue: monthValue,
            categoryID: categoryID,
            columns: columns,
            db: db
        )
        let rowID = existingRowID ?? Self.budgetRowID(monthValue: monthValue, categoryID: categoryID)
        let dataset = table.rawValue
        var messages: [ActualSyncDecodedMessage] = []
        messages.append(
            try builder.makeMessage(
                dataset: dataset,
                row: rowID,
                column: "month",
                value: .int(Int64(monthValue))
            )
        )
        messages.append(
            try builder.makeMessage(
                dataset: dataset,
                row: rowID,
                column: "category",
                value: .string(categoryID)
            )
        )
        if existingRowID == nil, columns.contains("carryover") {
            messages.append(
                try builder.makeMessage(
                    dataset: dataset,
                    row: rowID,
                    column: "carryover",
                    value: .bool(false)
                )
            )
        }
        messages.append(
            try builder.makeMessage(
                dataset: dataset,
                row: rowID,
                column: "goal",
                value: goal.map { .int(Int64($0)) } ?? .null
            )
        )
        if columns.contains("long_goal") {
            messages.append(
                try builder.makeMessage(
                    dataset: dataset,
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

    func isGoalOnly(_ entries: [BudgetTemplateEntry]) -> Bool {
        !entries.contains {
            $0.directive == "template" && $0.type != "limit"
        } && entries.contains(where: \.isGoal)
    }
}
