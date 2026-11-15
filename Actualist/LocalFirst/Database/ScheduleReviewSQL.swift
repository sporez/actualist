import Foundation
import GRDB

struct ScheduleMutationCurrentState: Sendable {
    let review: ScheduleMutationReview
    let projection: ScheduleRuleProjection

    var effectiveNextDate: String? { review.uniqueNextDate?.effectiveDate }
    var accountID: String? { projection.accountID }
}

enum ScheduleReviewSQL {
    static func scheduleRequiredColumns(
        table: String,
        required: [String],
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> Set<String> {
        do {
            return try database.requiredColumns(table: table, required: required, db: db)
        } catch LocalFirstError.schemaUnavailable {
            throw ScheduleMutationCommandError.unsupportedSchema
        }
    }

    static func scheduleMutationReview(
        budgetID: String,
        scheduleID: String,
        in database: isolated BudgetDatabase
    ) throws -> ScheduleMutationReview {
        try database.queue.read { db in
            try captureScheduleMutationReview(budgetID: budgetID, scheduleID: scheduleID, in: database, db: db)
        }
    }

    static func validateScheduleMutationReview(
        _ review: ScheduleMutationReview,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> ScheduleMutationCurrentState {
        let current = try captureScheduleMutationReview(
            budgetID: review.budgetID,
            scheduleID: review.scheduleID,
            in: database,
            db: db
        )
        guard current == review else {
            throw ScheduleMutationCommandError.reviewChanged
        }
        guard current.rule.tombstone == false else {
            throw ScheduleMutationCommandError.unsupportedCapability("The schedule's linked rule is missing.")
        }
        let projection = ScheduleRuleProjection.read(
            scheduleID: current.scheduleID,
            conditionsJSON: current.rule.conditionsJSON,
            actionsJSON: current.rule.actionsJSON
        )
        guard projection.capabilities.canDelete else {
            throw ScheduleMutationCommandError.unsupportedCapability("The schedule's rule link cannot be edited safely.")
        }
        guard try !ScheduleSQL.scheduleRuleHasAnotherLiveOwner(
            ruleID: current.ruleID,
            scheduleID: current.scheduleID,
            in: database,
            db: db
        ) else {
            throw ScheduleMutationCommandError.unsupportedCapability("The schedule's rule is shared by another live schedule.")
        }
        return ScheduleMutationCurrentState(
            review: current,
            projection: projection
        )
    }

    private static func captureScheduleMutationReview(
        budgetID: String,
        scheduleID: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> ScheduleMutationReview {
        let scheduleColumns = try scheduleRequiredColumns(
            table: "schedules",
            required: ["id", "rule"],
            in: database,
            db: db
        )
        let scheduleFields = ["name", "completed", "posts_transaction", "custom_upcoming_length", "sort_order", "tombstone", "active"]
        let selection = scheduleFields.map { field in
            database.column(field, fallback: "NULL", columns: scheduleColumns) + " AS \(database.quotedIdentifier(field))"
        }.joined(separator: ", ")
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT rule, \(selection)
                FROM schedules
                WHERE id = ? AND \(database.predicateForLiveRows(columns: scheduleColumns))
                LIMIT 1
                """,
            arguments: [scheduleID]
        ),
        let ruleID = row["rule"] as String?, !ruleID.isEmpty else {
            throw ScheduleMutationCommandError.reviewChanged
        }
        let name = row["name"] as String?
        let schedule = ScheduleRowRevision(
            name: name,
            completed: SQLiteValueCoercion.lenientBool(row["completed"]),
            postsTransaction: SQLiteValueCoercion.lenientBool(row["posts_transaction"]),
            customUpcomingLength: row["custom_upcoming_length"] as String?,
            sortOrder: SQLiteValueCoercion.lenientOptionalDouble(row["sort_order"]),
            tombstone: SQLiteValueCoercion.lenientBool(row["tombstone"]),
            active: SQLiteValueCoercion.lenientBool(row["active"])
        )

        let ruleColumns = try scheduleRequiredColumns(
            table: "rules",
            required: ["id", "tombstone"],
            in: database,
            db: db
        )
        let conditions = database.column("conditions", fallback: "NULL", columns: ruleColumns)
        let actions = database.column("actions", fallback: "NULL", columns: ruleColumns)
        let ruleSelection = ["stage", "conditions_op"].map { field in
            database.column(field, fallback: "NULL", columns: ruleColumns) + " AS \(database.quotedIdentifier(field))"
        }.joined(separator: ", ")
        guard let ruleRow = try Row.fetchOne(
            db,
            sql: """
                SELECT \(conditions) AS conditions, \(actions) AS actions, tombstone, \(ruleSelection)
                FROM rules
                WHERE id = ? AND \(database.predicateForLiveRows(columns: ruleColumns))
                LIMIT 1
                """,
            arguments: [ruleID]
        ) else {
            throw ScheduleMutationCommandError.unsupportedCapability("The schedule's linked rule is missing.")
        }
        let rule = ScheduleRuleRevision(
            conditionsJSON: ruleRow["conditions"],
            actionsJSON: ruleRow["actions"],
            stage: ruleRow["stage"],
            conditionsOperation: ruleRow["conditions_op"],
            tombstone: SQLiteValueCoercion.lenientBool(ruleRow["tombstone"])
        )

        let projection = ScheduleRuleProjection.read(
            scheduleID: scheduleID,
            conditionsJSON: rule.conditionsJSON,
            actionsJSON: rule.actionsJSON
        )
        let nextDates = try captureScheduleNextDates(scheduleID: scheduleID, in: database, db: db)
        let account = try projection.accountID.flatMap { try captureScheduleAccount(id: $0, in: database, db: db) }
        return ScheduleMutationReview(
            budgetID: budgetID,
            scheduleID: scheduleID,
            ruleID: ruleID,
            schedule: schedule,
            rule: rule,
            nextDates: nextDates,
            account: account
        )
    }

    private static func captureScheduleNextDates(
        scheduleID: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ScheduleNextDateRevision] {
        guard try database.tableExists("schedules_next_date", db: db) else { return [] }
        let columns = try database.columnSet(for: "schedules_next_date", db: db)
        guard columns.isSuperset(of: ["id", "schedule_id"]) else { return [] }
        let localDate = database.column("local_next_date", fallback: "NULL", columns: columns)
        let localTimestamp = database.column("local_next_date_ts", fallback: "NULL", columns: columns)
        let baseDate = database.column("base_next_date", fallback: "NULL", columns: columns)
        let baseTimestamp = database.column("base_next_date_ts", fallback: "NULL", columns: columns)
        let tombstone = database.column("tombstone", fallback: "0", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, \(localDate) AS local_next_date,
                       \(localTimestamp) AS local_next_date_ts,
                       \(baseDate) AS base_next_date,
                       \(baseTimestamp) AS base_next_date_ts,
                       \(tombstone) AS tombstone
                FROM schedules_next_date
                WHERE schedule_id = ?
                ORDER BY id
                """,
            arguments: [scheduleID]
        )
        return rows.compactMap { row in
            guard let id = row["id"] as String? else { return nil }
            return ScheduleNextDateRevision(
                id: id,
                localDate: SQLiteValueCoercion.lenientString(row["local_next_date"]),
                localTimestamp: SQLiteValueCoercion.lenientString(row["local_next_date_ts"]),
                baseDate: SQLiteValueCoercion.lenientString(row["base_next_date"]),
                baseTimestamp: SQLiteValueCoercion.lenientString(row["base_next_date_ts"]),
                tombstone: SQLiteValueCoercion.lenientBool(row["tombstone"])
            )
        }
    }

    private static func captureScheduleAccount(id: String, in database: isolated BudgetDatabase, db: Database) throws -> ScheduleAccountRevision? {
        guard try database.tableExists("accounts", db: db) else { return nil }
        let columns = try database.columnSet(for: "accounts", db: db)
        guard columns.contains("id") else { return nil }
        let name = database.column("name", fallback: "NULL", columns: columns)
        let offBudget = database.column("offbudget", fallback: "0", columns: columns)
        let closed = database.column("closed", fallback: "0", columns: columns)
        let tombstone = database.column("tombstone", fallback: "0", columns: columns)
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT \(name) AS name, \(offBudget) AS offbudget, \(closed) AS closed, \(tombstone) AS tombstone FROM accounts WHERE id = ? LIMIT 1",
            arguments: [id]
        ) else { return nil }
        return ScheduleAccountRevision(
            id: id,
            name: row["name"],
            offBudget: SQLiteValueCoercion.lenientBool(row["offbudget"]),
            isClosed: SQLiteValueCoercion.lenientBool(row["closed"]),
            tombstone: SQLiteValueCoercion.lenientBool(row["tombstone"])
        )
    }
}
