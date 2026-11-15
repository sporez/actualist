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

enum TemplateApplySQL {
    static func budgetTemplateApply(
        command: BudgetTemplateCommand,
        month: String,
        currentMonth: String? = nil,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> BudgetTemplateApplyResult {
        try database.queue.read { db in
            try budgetTemplateApply(
                command: command,
                month: month,
                currentMonth: currentMonth,
                builder: &builder,
                in: database,
                db: db
            )
        }
    }

    /// Plans from the live budget read through `db`, so an apply built in its own
    /// write transaction starts from the amounts and notes as they are at commit.
    static func budgetTemplateApply(
        command: BudgetTemplateCommand,
        month: String,
        currentMonth: String? = nil,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> BudgetTemplateApplyResult {
        let prepared = try TemplatePreviewSQL.budgetTemplatePlan(
            command: command,
            month: month,
            currentMonth: currentMonth,
            skipAvailableClamp: false,
            goalDefOverrides: [:],
            skipStaleCheck: false,
            in: database,
            db: db
        )
        let writes = prepared.compute.writes
        let table = prepared.table
        let columns = prepared.columns
        let canWriteGoals = prepared.canWriteGoals
        let orphanGoalCategoryIDs = prepared.orphanGoalCategoryIDs
        let monthValue = try BudgetDatabase.actualMonthValue(month)

        var messages: [ActualSyncDecodedMessage] = []
        for write in writes.sorted(by: { $0.categoryID < $1.categoryID }) {
            messages += try database.assignCategoryBudgetMessages(
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
                    builder: &builder,
                    in: database,
                    db: db
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
                    builder: &builder,
                    in: database,
                    db: db
                )
            }
        }
        messages += try tombstoneOrphanCleanupGroupMessages(builder: &builder, in: database, db: db)
        return BudgetTemplateApplyResult(
            messages: messages,
            assignments: writes.compactMap { write in
                guard prepared.currentBudgeted[write.categoryID] != write.amount else {
                    return nil
                }
                return BudgetTemplateAssignment(
                    categoryID: write.categoryID,
                    amount: write.amount
                )
            }
        )
    }

    static func categoryGoals(month: String, in database: isolated BudgetDatabase, db: Database) throws -> [String: Int] {
        guard let source = try database.categoryBudgetSource(db: db) else {
            return [:]
        }
        guard source.columns.contains("goal") else {
            return [:]
        }
        let category = database.column("category", fallback: "NULL", columns: source.columns)
        let budgetMonth = database.normalizedMonthExpression("month")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(category) AS category_id, goal
                FROM \(database.quotedIdentifier(source.table.rawValue))
                WHERE \(budgetMonth) = ? AND goal IS NOT NULL
                """,
            arguments: [month]
        )
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let categoryID = row["category_id"] as String? else {
                return nil
            }
            return (categoryID, row["goal"] ?? 0)
        })
    }

    private static func assignCategoryGoalMessages(
        categoryID: String,
        goal: Int?,
        longGoal: Int?,
        monthValue: Int,
        table: BudgetTable,
        columns: Set<String>,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        guard columns.contains("goal") else {
            return []
        }
        let existingRowID = try database.budgetRowID(
            table: table,
            monthValue: monthValue,
            categoryID: categoryID,
            columns: columns,
            db: db
        )
        let rowID = existingRowID ?? BudgetDatabase.budgetRowID(monthValue: monthValue, categoryID: categoryID)
        let dataset = table.rawValue
        var messages = try database.budgetRowIdentityMessages(
            table: table, rowID: rowID, monthValue: monthValue,
            categoryID: categoryID, builder: &builder
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

    private static func tombstoneOrphanCleanupGroupMessages(
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        guard try database.tableExists("cleanup_groups", db: db),
              try database.tableExists("categories", db: db) else {
            return []
        }
        let groupColumns = try database.columnSet(for: "cleanup_groups", db: db)
        let categoryColumns = try database.columnSet(for: "categories", db: db)
        guard groupColumns.contains("tombstone"),
              categoryColumns.contains("cleanup_def") else {
            return []
        }

        // An unreadable definition may reference any group, so fail closed: keep
        // every group rather than tombstone one that is still in use.
        let livePredicate = database.predicateForLiveRows(columns: categoryColumns, tableAlias: "c")
        let invalidDefinitions = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM categories c
                WHERE \(livePredicate)
                  AND c.cleanup_def IS NOT NULL
                  AND json_valid(c.cleanup_def) = 0
                """
        ) ?? 0
        guard invalidDefinitions == 0 else {
            return []
        }
        let referenced = try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT json_extract(je.value, '$.groupId') AS group_id
                FROM categories c, json_each(CASE WHEN json_valid(c.cleanup_def) THEN c.cleanup_def ELSE '[]' END) je
                WHERE \(livePredicate)
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
                WHERE \(database.predicateForLiveRows(columns: groupColumns))
                """
        )
        return try liveGroups.compactMap { row -> ActualSyncDecodedMessage? in
            guard let id = row["id"] as String?, !referencedIDs.contains(id) else {
                return nil
            }
            return try builder.tombstone(dataset: "cleanup_groups", row: id)
        }
    }
}
