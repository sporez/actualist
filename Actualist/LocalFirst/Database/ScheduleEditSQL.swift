import Foundation
import GRDB

private enum ScheduleWriteCommand: Sendable {
    case create(ScheduleCreateCommand)
    case update(ScheduleMutationReview, ScheduleEditFields, String, Date)
    case delete(ScheduleMutationReview)
    case skip(ScheduleMutationReview, Date)
    case complete(ScheduleMutationReview)
}

private struct ScheduleWriteDecision: Sendable {
    let messages: [ActualSyncDecodedMessage]
    let result: ScheduleMutationResult
    /// Actual v26.11.0 `allowAutoPostingToRunAgainToday`: creating or editing a schedule that posts
    /// transactions clears the day's auto-post marker, so a schedule due today still posts today.
    var allowsAutoPostingAgainToday = false
}

enum ScheduleEditSQL {
    static func createSchedule(_ command: ScheduleCreateCommand, now: Date = Date(), in database: isolated BudgetDatabase) throws -> ScheduleMutationResult {
        try commitScheduleMutation(.create(command), now: now, in: database)
    }

    static func updateSchedule(
        review: ScheduleMutationReview,
        fields: ScheduleEditFields,
        asOfDayID: String,
        now: Date,
        in database: isolated BudgetDatabase
    ) throws -> ScheduleMutationResult {
        try commitScheduleMutation(.update(review, fields, asOfDayID, now), now: now, in: database)
    }

    static func deleteSchedule(review: ScheduleMutationReview, now: Date = Date(), in database: isolated BudgetDatabase) throws -> ScheduleMutationResult {
        try commitScheduleMutation(.delete(review), now: now, in: database)
    }

    static func skipNextDate(review: ScheduleMutationReview, now: Date = Date(), in database: isolated BudgetDatabase) throws -> ScheduleMutationResult {
        try commitScheduleMutation(.skip(review, now), now: now, in: database)
    }

    static func completeSchedule(review: ScheduleMutationReview, now: Date = Date(), in database: isolated BudgetDatabase) throws -> ScheduleMutationResult {
        try commitScheduleMutation(.complete(review), now: now, in: database)
    }

    private static func commitScheduleMutation(
        _ command: ScheduleWriteCommand,
        now: Date,
        in database: isolated BudgetDatabase
    ) throws -> ScheduleMutationResult {
        try Task.checkCancellation()
        let committed = try database.commitLocalPlan(now: now) { db in
            let decision = try prepareScheduleWrite(command, now: now, in: database, db: db)
            return BudgetDatabase.LocalCommitPlan(
                drafts: decision.messages,
                action: nil,
                outcome: decision
            )
        }
        if committed.outcome.allowsAutoPostingAgainToday {
            SchedulePostingSQL.allowScheduleAutoPostingAgainToday(in: database)
        }
        return ScheduleMutationResult(
            scheduleID: committed.outcome.result.scheduleID,
            kind: committed.outcome.result.kind,
            appliedMessageCount: committed.appliedCount
        )
    }

    private static func prepareScheduleWrite(
        _ command: ScheduleWriteCommand,
        now: Date,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> ScheduleWriteDecision {
        try Task.checkCancellation()
        do {
            switch command {
            case .create(let command):
                return try prepareScheduleCreate(command, now: now, in: database, db: db)
            case .update(let review, let fields, let asOfDayID, let now):
                let current = try ScheduleReviewSQL.validateScheduleMutationReview(review, in: database, db: db)
                return try prepareScheduleUpdate(current, fields: fields, asOfDayID: asOfDayID, now: now, in: database, db: db)
            case .delete(let review):
                let current = try ScheduleReviewSQL.validateScheduleMutationReview(review, in: database, db: db)
                return try prepareScheduleDelete(current, in: database, db: db)
            case .skip(let review, let now):
                let current = try ScheduleReviewSQL.validateScheduleMutationReview(review, in: database, db: db)
                return try prepareScheduleSkip(current, now: now, in: database, db: db)
            case .complete(let review):
                let current = try ScheduleReviewSQL.validateScheduleMutationReview(review, in: database, db: db)
                return try prepareScheduleComplete(current, in: database, db: db)
            }
        } catch let error as ScheduleRuleMutationError {
            switch error {
            case .unsupportedField(let field):
                throw ScheduleMutationCommandError.unsupportedCapability("The schedule's \(field) condition cannot be edited safely.")
            case .malformedConditions, .malformedActions, .invalidDefinition, .invalidScheduleLink:
                throw ScheduleMutationCommandError.invalidCommand("The schedule definition cannot be changed safely.")
            }
        }
    }

    private static func prepareScheduleCreate(
        _ command: ScheduleCreateCommand,
        now: Date,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> ScheduleWriteDecision {
        guard !command.budgetID.isEmpty else {
            throw ScheduleMutationCommandError.invalidCommand("Schedule identifiers are invalid.")
        }
        try validateUniqueScheduleName(command.name, excludingScheduleID: command.identity.scheduleID, in: database, db: db)
        try validateScheduleAccount(command.definition.accountID, in: database, db: db)
        if let customUpcoming = command.customUpcomingLength {
            try validateUpcomingLength(customUpcoming)
        }
        if let payeeID = command.definition.payeeMappingID {
            try validateSchedulePayee(payeeID, in: database, db: db)
        }
        let json = try ScheduleRuleMutation.newRuleJSON(
            scheduleID: command.identity.scheduleID,
            definition: command.definition
        )
        let nextDate = try ScheduleRuleMutation.initialNextDate(
            for: command.definition.dateRule,
            asOf: command.asOfDayID
        )
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try ScheduleCreationMessagePlan.scheduleCreationMessages(
            ScheduleCreationMessagePlanRequest(
                identity: command.identity,
                name: normalizedScheduleName(command.name),
                postsTransaction: command.postsTransaction,
                customUpcomingLength: command.customUpcomingLength,
                conditionsJSON: json.conditions,
                actionsJSON: json.actions,
                nextDate: nextDate,
                now: now
            ),
            builder: &builder,
            in: database,
            db: db
        )
        return ScheduleWriteDecision(
            messages: messages,
            result: ScheduleMutationResult(scheduleID: command.identity.scheduleID, kind: .created,
                                           appliedMessageCount: 0),
            allowsAutoPostingAgainToday: command.postsTransaction
        )
    }

    private static func prepareScheduleUpdate(
        _ current: ScheduleMutationCurrentState,
        fields: ScheduleEditFields,
        asOfDayID: String,
        now: Date,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> ScheduleWriteDecision {
        guard !fields.isEmpty else { return unchanged(current.review.scheduleID) }
        let scheduleColumns = try ScheduleReviewSQL.scheduleRequiredColumns(
            table: "schedules", required: ["id", "rule", "completed", "posts_transaction", "tombstone"], in: database, db: db
        )
        _ = try ScheduleReviewSQL.scheduleRequiredColumns(table: "rules", required: ["id", "tombstone"], in: database, db: db)
        if fields.accountID != .unchanged && !current.projection.capabilities.canEditAccount {
            throw ScheduleMutationCommandError.unsupportedCapability("The schedule's account condition cannot be edited safely.")
        }
        if fields.payeeMappingID != .unchanged && !current.projection.capabilities.canEditPayee {
            throw ScheduleMutationCommandError.unsupportedCapability("The schedule's payee condition cannot be edited safely.")
        }
        if fields.amount != .unchanged && !current.projection.capabilities.canEditAmount {
            throw ScheduleMutationCommandError.unsupportedCapability("The schedule's amount condition cannot be edited safely.")
        }
        if fields.dateRule != .unchanged && !current.projection.capabilities.canEditDate {
            throw ScheduleMutationCommandError.unsupportedCapability("The schedule's date condition cannot be edited safely.")
        }

        let fields = normalizedScheduleEdits(fields, current: current)
        guard !fields.isEmpty else { return unchanged(current.review.scheduleID) }
        let newName: String?
        switch fields.name {
        case .unchanged: newName = current.review.schedule.name
        case .set(let name): newName = normalizedScheduleName(name)
        }
        if fields.name != .unchanged {
            guard scheduleColumns.contains("name") else {
                throw ScheduleMutationCommandError.unsupportedCapability("This budget does not support schedule names.")
            }
            try validateUniqueScheduleName(newName, excludingScheduleID: current.review.scheduleID, in: database, db: db)
        }
        if fields.customUpcomingLength != .unchanged {
            guard scheduleColumns.contains("custom_upcoming_length") else {
                throw ScheduleMutationCommandError.unsupportedCapability("This budget does not support a custom upcoming window.")
            }
            if case .set(let value?) = fields.customUpcomingLength {
                try validateUpcomingLength(value)
            }
        }
        if case .set(nil) = fields.accountID {
            throw ScheduleMutationCommandError.invalidCommand("A schedule account is required.")
        }
        let resetsNextDate = accountTargetChanged(fields.accountID, current: current)
            || dateTargetChanged(fields.dateRule, current: current)
            || fields.resetNextDate
        if resetsNextDate {
            let columns = try scheduleNextDateWriteColumns(in: database, db: db)
            guard columns.contains("base_next_date") && columns.contains("base_next_date_ts"),
                  let next = current.review.uniqueNextDate else {
                throw ScheduleMutationCommandError.unsupportedCapability("The schedule's next date is unavailable or ambiguous.")
            }
            guard next.baseTimestamp.flatMap(Int64.init) != nil else {
                throw ScheduleMutationCommandError.unsupportedCapability("The schedule's base date cannot be updated safely.")
            }
        }
        if accountTargetChanged(fields.accountID, current: current),
           case .set(let accountID?) = fields.accountID {
            try validateScheduleAccount(accountID, in: database, db: db)
        }
        if case .set(let payeeID?) = fields.payeeMappingID,
           payeeID != current.projection.payeeMappingID {
            try validateSchedulePayee(payeeID, in: database, db: db)
        }
        var builder = LocalFirstSyncMessageBuilder()
        var messages: [ActualSyncDecodedMessage] = []
        let mutationFields = fields.changesDefinition ? fields : ScheduleEditFields()
        if fields.changesDefinition {
            _ = try ScheduleReviewSQL.scheduleRequiredColumns(table: "rules", required: ["id", "conditions", "actions", "tombstone"], in: database, db: db)
            guard let oldConditions = current.review.rule.conditionsJSON,
                  let oldActions = current.review.rule.actionsJSON else {
                throw ScheduleMutationCommandError.unsupportedCapability("The schedule definition is unavailable.")
            }
            let merged = try ScheduleRuleMutation.merge(
                conditionsJSON: oldConditions,
                actionsJSON: oldActions,
                scheduleID: current.review.scheduleID,
                edits: mutationFields
            )
            if let conditions = merged.conditions {
                messages.append(try builder.makeMessage(
                    dataset: "rules", row: current.review.ruleID, column: "conditions", value: .string(conditions)
                ))
            }
            if let actions = merged.actions {
                messages.append(try builder.makeMessage(
                    dataset: "rules", row: current.review.ruleID, column: "actions", value: .string(actions)
                ))
            }
        }
        if fields.name != .unchanged {
            messages.append(try builder.makeMessage(
                dataset: "schedules", row: current.review.scheduleID, column: "name",
                value: newName.map(LocalFirstSyncValue.string) ?? .null
            ))
        }
        if let posts = fields.postsTransaction, posts != current.review.schedule.postsTransaction {
            messages.append(try builder.makeMessage(
                dataset: "schedules", row: current.review.scheduleID, column: "posts_transaction", value: .bool(posts)
            ))
        }
        if fields.customUpcomingLength != .unchanged {
            if case .set(let value) = fields.customUpcomingLength,
               value != current.review.schedule.customUpcomingLength {
                messages.append(try builder.makeMessage(
                    dataset: "schedules", row: current.review.scheduleID, column: "custom_upcoming_length",
                    value: value.map(LocalFirstSyncValue.string) ?? .null
                ))
            }
        }
        if resetsNextDate {
            let definition = try updatedDateRule(fields.dateRule, current: current)
            if let nextDate = try ScheduleRuleMutation.updateNextDate(
                for: definition,
                asOf: asOfDayID,
                currentEffectiveDate: current.effectiveNextDate
            ) {
                guard let next = current.review.uniqueNextDate else {
                    throw ScheduleMutationCommandError.unsupportedCapability("The schedule's next date is unavailable.")
                }
                messages += try nextDateMessages(
                    rowID: next.id,
                    date: nextDate,
                    base: true,
                    baseTimestamp: next.baseTimestamp,
                    resetTimestamp: now,
                    builder: &builder
                )
            }
        }
        guard !messages.isEmpty else { return unchanged(current.review.scheduleID) }
        return ScheduleWriteDecision(
            messages: messages,
            result: ScheduleMutationResult(scheduleID: current.review.scheduleID, kind: .updated,
                                           appliedMessageCount: 0),
            // An unchanged posting flag was normalized to nil, so this is the flag after the edit.
            allowsAutoPostingAgainToday: fields.postsTransaction ?? current.review.schedule.postsTransaction
        )
    }

    private static func prepareScheduleDelete(
        _ current: ScheduleMutationCurrentState,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> ScheduleWriteDecision {
        _ = try ScheduleReviewSQL.scheduleRequiredColumns(table: "schedules", required: ["id", "rule", "tombstone"], in: database, db: db)
        _ = try ScheduleReviewSQL.scheduleRequiredColumns(table: "rules", required: ["id", "tombstone"], in: database, db: db)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = [
            try builder.tombstone(dataset: "rules", row: current.review.ruleID),
            try builder.tombstone(dataset: "schedules", row: current.review.scheduleID)
        ]
        return ScheduleWriteDecision(
            messages: messages,
            result: ScheduleMutationResult(scheduleID: current.review.scheduleID, kind: .deleted,
                                           appliedMessageCount: messages.count)
        )
    }

    private static func prepareScheduleSkip(
        _ current: ScheduleMutationCurrentState,
        now: Date,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> ScheduleWriteDecision {
        guard let recurrence = current.projection.dateRule.recurrence,
              let next = current.review.uniqueNextDate,
              let effectiveDate = current.effectiveNextDate else {
            throw ScheduleMutationCommandError.unsupportedCapability("The schedule recurrence or next date is unsupported.")
        }
        let columns = try scheduleNextDateWriteColumns(in: database, db: db)
        guard columns.contains("local_next_date") && columns.contains("local_next_date_ts") else {
            throw ScheduleMutationCommandError.unsupportedCapability("This budget does not support schedule next dates.")
        }
        guard let updated = try ScheduleRuleMutation.nextDateAfterSkip(
            recurrence: recurrence,
            currentDayID: effectiveDate
        ), updated != effectiveDate else {
            return unchanged(current.review.scheduleID)
        }
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try nextDateMessages(
            rowID: next.id,
            date: updated,
            base: false,
            baseTimestamp: next.baseTimestamp,
            resetTimestamp: now,
            builder: &builder
        )
        return ScheduleWriteDecision(
            messages: messages,
            result: ScheduleMutationResult(scheduleID: current.review.scheduleID, kind: .skipped,
                                           appliedMessageCount: messages.count)
        )
    }

    private static func prepareScheduleComplete(
        _ current: ScheduleMutationCurrentState,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> ScheduleWriteDecision {
        let scheduleColumns = try ScheduleReviewSQL.scheduleRequiredColumns(
            table: "schedules", required: ["id", "rule", "completed", "tombstone"], in: database, db: db
        )
        guard scheduleColumns.contains("completed") else {
            throw ScheduleMutationCommandError.unsupportedCapability("This budget does not support completing schedules.")
        }
        guard case .oneTime = current.projection.dateRule,
              !current.review.schedule.completed else {
            if current.review.schedule.completed {
                return unchanged(current.review.scheduleID)
            }
            throw ScheduleMutationCommandError.unsupportedCapability("Only a supported one-time schedule can be completed.")
        }
        var builder = LocalFirstSyncMessageBuilder()
        let messages = [try builder.makeMessage(
            dataset: "schedules", row: current.review.scheduleID, column: "completed", value: .bool(true)
        )]
        return ScheduleWriteDecision(
            messages: messages,
            result: ScheduleMutationResult(scheduleID: current.review.scheduleID, kind: .completed,
                                           appliedMessageCount: messages.count)
        )
    }

    private static func scheduleNextDateWriteColumns(in database: isolated BudgetDatabase, db: Database) throws -> Set<String> {
        try ScheduleReviewSQL.scheduleRequiredColumns(
            table: "schedules_next_date",
            required: ["id", "schedule_id", "local_next_date", "local_next_date_ts", "base_next_date", "base_next_date_ts", "tombstone"],
            in: database,
            db: db
        )
    }

    private static func nextDateMessages(
        rowID: String,
        date: String,
        base: Bool,
        baseTimestamp: String?,
        resetTimestamp: Date,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard let baseTimestamp = baseTimestamp.flatMap(Int64.init) else {
            throw ScheduleMutationCommandError.unsupportedCapability("The schedule's base date cannot be updated safely.")
        }
        if base {
            let timestamp = Int64((resetTimestamp.timeIntervalSince1970 * 1_000).rounded(.towardZero))
            return [
                try builder.makeMessage(dataset: "schedules_next_date", row: rowID, column: "base_next_date",
                                        value: scheduleDateValue(date)),
                try builder.makeMessage(dataset: "schedules_next_date", row: rowID, column: "base_next_date_ts",
                                        value: .int(timestamp))
            ]
        }
        return [
            try builder.makeMessage(dataset: "schedules_next_date", row: rowID, column: "local_next_date",
                                    value: scheduleDateValue(date)),
            try builder.makeMessage(dataset: "schedules_next_date", row: rowID, column: "local_next_date_ts",
                                    value: .int(baseTimestamp))
        ]
    }

    static func scheduleDateValue(_ dayID: String) throws -> LocalFirstSyncValue {
        guard let value = Int64(PackedDate.compact(dayID)),
              ActualScheduleRecurrence.date(from: dayID) != nil else {
            throw ScheduleMutationCommandError.invalidCommand("The schedule date is invalid.")
        }
        return .int(value)
    }

    private static func validateScheduleAccount(_ accountID: String, in database: isolated BudgetDatabase, db: Database) throws {
        _ = try ScheduleReviewSQL.scheduleRequiredColumns(table: "accounts", required: ["id", "closed", "tombstone"], in: database, db: db)
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT closed, tombstone FROM accounts WHERE id = ? LIMIT 1",
            arguments: [accountID]
        ), !SQLiteValueCoercion.lenientBool(row["closed"]), !SQLiteValueCoercion.lenientBool(row["tombstone"]) else {
            throw ScheduleMutationCommandError.invalidCommand("Choose an available, open account for this schedule.")
        }
    }

    private static func validateSchedulePayee(_ payeeMappingID: String, in database: isolated BudgetDatabase, db: Database) throws {
        let mappingColumns = try ScheduleReviewSQL.scheduleRequiredColumns(table: "payee_mapping", required: ["id"], in: database, db: db)
        let targetColumn: String
        do {
            targetColumn = try database.firstExistingColumn(
                PayeeMappingColumns.targetAliases,
                in: mappingColumns,
                table: "payee_mapping"
            )
        } catch LocalFirstError.invalidLocalWrite {
            throw ScheduleMutationCommandError.unsupportedSchema
        }
        let payeeColumns = try ScheduleReviewSQL.scheduleRequiredColumns(table: "payees", required: ["id"], in: database, db: db)
        guard try Row.fetchOne(
            db,
            sql: """
                SELECT mapping.id
                FROM payee_mapping AS mapping
                JOIN payees AS payee ON payee.id = mapping.\(database.quotedIdentifier(targetColumn))
                WHERE mapping.id = ?
                    AND mapping.\(database.quotedIdentifier(targetColumn)) IS NOT NULL
                    AND \(database.predicateForLiveRows(columns: mappingColumns, tableAlias: "mapping"))
                    AND \(database.predicateForLiveRows(columns: payeeColumns, tableAlias: "payee"))
                LIMIT 1
                """,
            arguments: [payeeMappingID]
        ) != nil else {
            throw ScheduleMutationCommandError.invalidCommand("The selected schedule payee is unavailable.")
        }
    }

    private static func validateUniqueScheduleName(
        _ rawName: String?,
        excludingScheduleID: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws {
        guard let name = normalizedScheduleName(rawName) else { return }
        _ = try ScheduleReviewSQL.scheduleRequiredColumns(table: "schedules", required: ["id", "name", "tombstone"], in: database, db: db)
        let duplicate = try Row.fetchOne(
            db,
            sql: "SELECT id FROM schedules WHERE tombstone = 0 AND name = ? AND id != ? LIMIT 1",
            arguments: [name, excludingScheduleID]
        ) != nil
        guard !duplicate else { throw ScheduleMutationCommandError.duplicateName }
    }

    private static func normalizedScheduleName(_ rawName: String?) -> String? {
        guard let trimmed = rawName?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func validateUpcomingLength(_ value: String) throws {
        let valid: Bool
        switch value {
        case "currentMonth", "oneMonth": valid = true
        default:
            if let days = Int(value) {
                valid = days >= 0
            } else {
                let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
                valid = pieces.count == 2
                    && Int(pieces[0]).map { $0 > 0 } == true
                    && ["day", "week", "month", "year"].contains(String(pieces[1]))
            }
        }
        guard valid else { throw ScheduleMutationCommandError.invalidCommand("The custom upcoming window is invalid.") }
    }

    private static func normalizedScheduleEdits(
        _ edits: ScheduleEditFields,
        current: ScheduleMutationCurrentState
    ) -> ScheduleEditFields {
        var result = edits
        if case .set(let name) = result.name,
           normalizedScheduleName(name) == normalizedScheduleName(current.review.schedule.name) {
            result.name = .unchanged
        }
        if case .set(let accountID?) = result.accountID, accountID == current.projection.accountID {
            result.accountID = .unchanged
        }
        if case .set(let payeeID) = result.payeeMappingID,
           payeeID == current.projection.payeeMappingID {
            result.payeeMappingID = .unchanged
        }
        if case .set(let amount?) = result.amount, amountMatches(amount, current.projection.amount) {
            result.amount = .unchanged
        }
        if case .set(let dateRule?) = result.dateRule, dateRule == current.projection.dateRule {
            result.dateRule = .unchanged
        }
        if let posts = result.postsTransaction, posts == current.review.schedule.postsTransaction {
            result.postsTransaction = nil
        }
        if case .set(let upcoming) = result.customUpcomingLength,
           upcoming == current.review.schedule.customUpcomingLength {
            result.customUpcomingLength = .unchanged
        }
        return result
    }

    private static func amountMatches(_ draft: ScheduleAmountDraft, _ amount: ScheduleAmount) -> Bool {
        switch (draft, amount) {
        case (.exact(let proposed), .exact(let current)),
             (.approximate(let proposed), .approximate(let current)):
            proposed == current
        case let (.range(proposedLower, proposedUpper), .range(lower, upper, _)):
            proposedLower == lower && proposedUpper == upper
        default:
            false
        }
    }

    private static func accountTargetChanged(
        _ change: ScheduleOptionalChange<String>,
        current: ScheduleMutationCurrentState
    ) -> Bool {
        guard case .set(let id?) = change else { return false }
        return id != current.accountID
    }

    private static func dateTargetChanged(
        _ change: ScheduleOptionalChange<ScheduleDateRule>,
        current: ScheduleMutationCurrentState
    ) -> Bool {
        guard case .set(let date?) = change,
              current.projection.dateRule != .unavailable else { return false }
        let previous = current.projection.dateRule
        return date != previous
    }

    private static func updatedDateRule(
        _ change: ScheduleOptionalChange<ScheduleDateRule>,
        current: ScheduleMutationCurrentState
    ) throws -> ScheduleDateRule {
        if case .set(let date?) = change { return date }
        guard current.projection.dateRule != .unavailable else {
            throw ScheduleMutationCommandError.unsupportedCapability("The schedule's date condition cannot be edited safely.")
        }
        return current.projection.dateRule
    }

    private static func unchanged(_ scheduleID: String) -> ScheduleWriteDecision {
        ScheduleWriteDecision(
            messages: [],
            result: ScheduleMutationResult(scheduleID: scheduleID, kind: .unchanged, appliedMessageCount: 0)
        )
    }
}
