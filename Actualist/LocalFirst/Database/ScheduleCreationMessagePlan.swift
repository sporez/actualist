import Foundation
import GRDB

struct ScheduleCreationMessagePlanRequest: Sendable {
    let identity: ScheduleCreateIdentity
    let name: String?
    let postsTransaction: Bool
    let customUpcomingLength: String?
    let conditionsJSON: String
    let actionsJSON: String
    let nextDate: String?
    let now: Date
}

/// Shared schedule/rule/next-date row and CRDT plan for ordinary authoring and
/// transaction conversion. Callers supply their own raw rule JSON semantics.
/// Like Actual's `db.insert`, no message names the `id` column: the CRDT row id
/// is the identity and applying the first field message creates the row.
extension BudgetDatabase {
    func scheduleCreationMessages(
        _ request: ScheduleCreationMessagePlanRequest,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let scheduleColumns = try scheduleRequiredColumns(
            table: "schedules",
            required: ["id", "rule", "completed", "posts_transaction", "tombstone"],
            db: db
        )
        let ruleColumns = try scheduleRequiredColumns(
            table: "rules",
            required: ["id", "conditions", "actions", "tombstone"],
            db: db
        )
        _ = try scheduleRequiredColumns(
            table: "schedules_next_date",
            required: ["id", "schedule_id", "local_next_date", "local_next_date_ts", "base_next_date", "base_next_date_ts", "tombstone"],
            db: db
        )
        let ids = [request.identity.scheduleID, request.identity.ruleID, request.identity.nextDateID]
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
            throw ScheduleMutationCommandError.invalidCommand("Schedule identifiers are invalid.")
        }
        for (table, id) in zip(["schedules", "rules", "schedules_next_date"], ids)
        where try rowExists(table: table, rowID: id, db: db) {
            throw ScheduleMutationCommandError.identityConflict
        }

        var messages = try scheduleRuleMessages(
            ruleID: request.identity.ruleID,
            conditionsJSON: request.conditionsJSON,
            actionsJSON: request.actionsJSON,
            columns: ruleColumns,
            builder: &builder
        )
        let scheduleValues: [(String, LocalFirstSyncValue)] = [
            ("rule", .string(request.identity.ruleID)),
            ("completed", .bool(false)),
            ("posts_transaction", .bool(request.postsTransaction)),
            ("tombstone", .bool(false))
        ]
        for (column, value) in scheduleValues {
            messages.append(try builder.makeMessage(
                dataset: "schedules", row: request.identity.scheduleID, column: column, value: value
            ))
        }
        if scheduleColumns.contains("name") {
            messages.append(try builder.makeMessage(
                dataset: "schedules", row: request.identity.scheduleID, column: "name",
                value: request.name.map(LocalFirstSyncValue.string) ?? .null
            ))
        } else if request.name != nil {
            throw ScheduleMutationCommandError.unsupportedCapability("This budget does not support schedule names.")
        }
        if let upcoming = request.customUpcomingLength {
            guard scheduleColumns.contains("custom_upcoming_length") else {
                throw ScheduleMutationCommandError.unsupportedCapability("This budget does not support a custom upcoming window.")
            }
            messages.append(try builder.makeMessage(
                dataset: "schedules", row: request.identity.scheduleID,
                column: "custom_upcoming_length", value: .string(upcoming)
            ))
        }
        if scheduleColumns.contains("sort_order") {
            messages.append(try builder.makeMessage(
                dataset: "schedules", row: request.identity.scheduleID, column: "sort_order", value: .double(0)
            ))
        }
        let timestamp = Int64((request.now.timeIntervalSince1970 * 1_000).rounded(.towardZero))
        let dateValue = try request.nextDate.map { try scheduleDateValue($0) } ?? .null
        messages += [
            try builder.makeMessage(dataset: "schedules_next_date", row: request.identity.nextDateID,
                                    column: "schedule_id", value: .string(request.identity.scheduleID)),
            try builder.makeMessage(dataset: "schedules_next_date", row: request.identity.nextDateID,
                                    column: "local_next_date", value: dateValue),
            try builder.makeMessage(dataset: "schedules_next_date", row: request.identity.nextDateID,
                                    column: "local_next_date_ts", value: .int(timestamp)),
            try builder.makeMessage(dataset: "schedules_next_date", row: request.identity.nextDateID,
                                    column: "base_next_date", value: dateValue),
            try builder.makeMessage(dataset: "schedules_next_date", row: request.identity.nextDateID,
                                    column: "base_next_date_ts", value: .int(timestamp)),
            try builder.makeMessage(dataset: "schedules_next_date", row: request.identity.nextDateID,
                                    column: "tombstone", value: .bool(false))
        ]
        return messages
    }

    private func scheduleRuleMessages(
        ruleID: String,
        conditionsJSON: String,
        actionsJSON: String,
        columns: Set<String>,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        var messages = [
            try builder.makeMessage(dataset: "rules", row: ruleID, column: "conditions", value: .string(conditionsJSON)),
            try builder.makeMessage(dataset: "rules", row: ruleID, column: "actions", value: .string(actionsJSON))
        ]
        if columns.contains("stage") {
            messages.append(try builder.makeMessage(dataset: "rules", row: ruleID, column: "stage", value: .null))
        }
        if columns.contains("conditions_op") {
            messages.append(try builder.makeMessage(
                dataset: "rules", row: ruleID, column: "conditions_op", value: .string("and")
            ))
        }
        messages.append(try builder.makeMessage(dataset: "rules", row: ruleID, column: "tombstone", value: .bool(false)))
        return messages
    }
}
