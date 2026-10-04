import Foundation
import GRDB

struct ScheduleMutationCurrentState: Sendable {
    let review: ScheduleMutationReview
    let projection: ScheduleRuleProjection

    var effectiveNextDate: String? { review.uniqueNextDate?.effectiveDate }
    var accountID: String? { projection.accountID }
}

extension BudgetDatabase {
    func scheduleRequiredColumns(
        table: String,
        required: [String],
        db: Database
    ) throws -> Set<String> {
        do {
            return try requiredColumns(table: table, required: required, db: db)
        } catch LocalFirstError.invalidLocalWrite {
            throw ScheduleMutationCommandError.unsupportedSchema
        }
    }

    func scheduleMutationReview(
        budgetID: String,
        scheduleID: String
    ) throws -> ScheduleMutationReview {
        try queue.read { db in
            try captureScheduleMutationReview(budgetID: budgetID, scheduleID: scheduleID, db: db)
        }
    }

    func validateScheduleMutationReview(
        _ review: ScheduleMutationReview,
        db: Database
    ) throws -> ScheduleMutationCurrentState {
        let current = try captureScheduleMutationReview(
            budgetID: review.budgetID,
            scheduleID: review.scheduleID,
            db: db
        )
        guard current == review else {
            throw ScheduleMutationCommandError.reviewChanged
        }
        guard current.rule.tombstone == false else {
            throw ScheduleMutationCommandError.unsupportedCapability("The schedule's linked rule is unavailable.")
        }
        let projection = ScheduleRuleProjection.read(
            scheduleID: current.scheduleID,
            conditionsJSON: current.rule.conditionsJSON,
            actionsJSON: current.rule.actionsJSON
        )
        guard projection.capabilities.canDelete else {
            throw ScheduleMutationCommandError.unsupportedCapability("The schedule's rule link cannot be edited safely.")
        }
        guard try !scheduleRuleHasAnotherLiveOwner(
            ruleID: current.ruleID,
            scheduleID: current.scheduleID,
            db: db
        ) else {
            throw ScheduleMutationCommandError.unsupportedCapability("The schedule's rule is shared by another live schedule.")
        }
        return ScheduleMutationCurrentState(
            review: current,
            projection: projection
        )
    }

    private func captureScheduleMutationReview(
        budgetID: String,
        scheduleID: String,
        db: Database
    ) throws -> ScheduleMutationReview {
        let scheduleColumns = try scheduleRequiredColumns(
            table: "schedules",
            required: ["id", "rule"],
            db: db
        )
        let scheduleFields = ["name", "completed", "posts_transaction", "custom_upcoming_length", "sort_order", "tombstone", "active"]
        let selection = scheduleFields.map { field in
            column(field, fallback: "NULL", columns: scheduleColumns) + " AS \(quotedIdentifier(field))"
        }.joined(separator: ", ")
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT rule, \(selection)
                FROM schedules
                WHERE id = ? AND \(predicateForLiveRows(columns: scheduleColumns))
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
            completed: flexibleBool(row["completed"]),
            postsTransaction: flexibleBool(row["posts_transaction"]),
            customUpcomingLength: row["custom_upcoming_length"] as String?,
            sortOrder: optionalScheduleDouble(row["sort_order"]),
            tombstone: flexibleBool(row["tombstone"]),
            active: flexibleBool(row["active"])
        )

        let ruleColumns = try scheduleRequiredColumns(
            table: "rules",
            required: ["id", "tombstone"],
            db: db
        )
        let conditions = column("conditions", fallback: "NULL", columns: ruleColumns)
        let actions = column("actions", fallback: "NULL", columns: ruleColumns)
        let ruleSelection = ["stage", "conditions_op"].map { field in
            column(field, fallback: "NULL", columns: ruleColumns) + " AS \(quotedIdentifier(field))"
        }.joined(separator: ", ")
        guard let ruleRow = try Row.fetchOne(
            db,
            sql: """
                SELECT \(conditions) AS conditions, \(actions) AS actions, tombstone, \(ruleSelection)
                FROM rules
                WHERE id = ? AND \(predicateForLiveRows(columns: ruleColumns))
                LIMIT 1
                """,
            arguments: [ruleID]
        ) else {
            throw ScheduleMutationCommandError.unsupportedCapability("The schedule's linked rule is unavailable.")
        }
        let rule = ScheduleRuleRevision(
            conditionsJSON: ruleRow["conditions"],
            actionsJSON: ruleRow["actions"],
            stage: ruleRow["stage"],
            conditionsOperation: ruleRow["conditions_op"],
            tombstone: flexibleBool(ruleRow["tombstone"])
        )

        let projection = ScheduleRuleProjection.read(
            scheduleID: scheduleID,
            conditionsJSON: rule.conditionsJSON,
            actionsJSON: rule.actionsJSON
        )
        let nextDates = try captureScheduleNextDates(scheduleID: scheduleID, db: db)
        let account = try projection.accountID.flatMap { try captureScheduleAccount(id: $0, db: db) }
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

    private func captureScheduleNextDates(
        scheduleID: String,
        db: Database
    ) throws -> [ScheduleNextDateRevision] {
        guard try tableExists("schedules_next_date", db: db) else { return [] }
        let columns = try columnSet(for: "schedules_next_date", db: db)
        guard columns.isSuperset(of: ["id", "schedule_id"]) else { return [] }
        let localDate = column("local_next_date", fallback: "NULL", columns: columns)
        let localTimestamp = column("local_next_date_ts", fallback: "NULL", columns: columns)
        let baseDate = column("base_next_date", fallback: "NULL", columns: columns)
        let baseTimestamp = column("base_next_date_ts", fallback: "NULL", columns: columns)
        let tombstone = column("tombstone", fallback: "0", columns: columns)
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
                localDate: flexibleString(row["local_next_date"]),
                localTimestamp: flexibleString(row["local_next_date_ts"]),
                baseDate: flexibleString(row["base_next_date"]),
                baseTimestamp: flexibleString(row["base_next_date_ts"]),
                tombstone: flexibleBool(row["tombstone"])
            )
        }
    }

    private func captureScheduleAccount(id: String, db: Database) throws -> ScheduleAccountRevision? {
        guard try tableExists("accounts", db: db) else { return nil }
        let columns = try columnSet(for: "accounts", db: db)
        guard columns.contains("id") else { return nil }
        let name = column("name", fallback: "NULL", columns: columns)
        let offBudget = column("offbudget", fallback: "0", columns: columns)
        let closed = column("closed", fallback: "0", columns: columns)
        let tombstone = column("tombstone", fallback: "0", columns: columns)
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT \(name) AS name, \(offBudget) AS offbudget, \(closed) AS closed, \(tombstone) AS tombstone FROM accounts WHERE id = ? LIMIT 1",
            arguments: [id]
        ) else { return nil }
        return ScheduleAccountRevision(
            id: id,
            name: row["name"],
            offBudget: flexibleBool(row["offbudget"]),
            isClosed: flexibleBool(row["closed"]),
            tombstone: flexibleBool(row["tombstone"])
        )
    }
}
