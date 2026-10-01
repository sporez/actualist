import Foundation
import GRDB

extension BudgetDatabase {
    func fetchSchedules(budgetID: String, today: String) throws -> LoadedSchedules {
        try queue.read { db in
            try fetchSchedules(budgetID: budgetID, today: today, db: db)
        }
    }

    func fetchSchedules(
        budgetID: String,
        today: String,
        db: Database
    ) throws -> LoadedSchedules {
        guard try tableExists("schedules", db: db) else {
            return .empty(budgetID: budgetID)
        }
        let scheduleColumns = try columnSet(for: "schedules", db: db)
        guard scheduleColumns.contains("id") else {
            return .empty(budgetID: budgetID)
        }

        let defaultUpcomingLength = try scheduleUpcomingLength(db: db)
        let rules = try scheduleRuleRows(db: db)
        let nextDates = try scheduleNextDateRows(db: db)
        let nextDateColumns: Set<String>
        if try tableExists("schedules_next_date", db: db) {
            nextDateColumns = try columnSet(for: "schedules_next_date", db: db)
        } else {
            nextDateColumns = []
        }
        let supportsNextDateWrites = [
            "id", "schedule_id", "local_next_date", "local_next_date_ts",
            "base_next_date", "base_next_date_ts", "tombstone"
        ].allSatisfy(nextDateColumns.contains)
        let supportsScheduleRuleEdit = ["id", "rule", "completed", "posts_transaction", "tombstone"]
            .allSatisfy(scheduleColumns.contains)
        let supportsScheduleMetadataEdit = supportsScheduleRuleEdit
            && ["name", "custom_upcoming_length"].allSatisfy(scheduleColumns.contains)
        let supportsScheduleCompletion = ["id", "rule", "completed", "tombstone"]
            .allSatisfy(scheduleColumns.contains)
        let supportsScheduleDeletion = ["id", "rule", "tombstone"].allSatisfy(scheduleColumns.contains)
        let ruleColumns: Set<String>
        if try tableExists("rules", db: db) {
            ruleColumns = try columnSet(for: "rules", db: db)
        } else {
            ruleColumns = []
        }
        let supportsScheduleRuleDeletion = ["id", "tombstone"].allSatisfy(ruleColumns.contains)
        // Authoring (create and transaction conversion) shares the
        // scheduleCreationMessages column requirements exactly; gating on this
        // signal keeps the entry points and the write path in agreement.
        let supportsAuthoring = supportsScheduleRuleEdit
            && supportsNextDateWrites
            && ["id", "conditions", "actions", "tombstone"].allSatisfy(ruleColumns.contains)
        let accountFacts = try scheduleAccountFacts(db: db)
        let payeeFacts = try schedulePayeeFacts(db: db)
        let payeeTargets = try schedulePayeeTargets(db: db)

        let name = column("name", fallback: "NULL", columns: scheduleColumns)
        let rule = column("rule", fallback: "NULL", columns: scheduleColumns)
        let completed = column("completed", fallback: "0", columns: scheduleColumns)
        let posts = column("posts_transaction", fallback: "0", columns: scheduleColumns)
        let customUpcoming = column("custom_upcoming_length", fallback: "NULL", columns: scheduleColumns)
        let sortOrder = column("sort_order", fallback: "NULL", columns: scheduleColumns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, \(name) AS name, \(rule) AS rule,
                       \(completed) AS completed, \(posts) AS posts_transaction,
                       \(customUpcoming) AS custom_upcoming_length,
                       \(sortOrder) AS sort_order
                FROM schedules
                WHERE \(predicateForLiveRows(columns: scheduleColumns))
                """
        )

        var projectionsByScheduleID: [String: ScheduleRuleProjection] = [:]
        var transactionLowerBounds: [String: String] = [:]
        for row in rows {
            guard let id = row["id"] as String?, !id.isEmpty else { continue }
            let ruleID = row["rule"] as String?
            let rawRule = ruleID.flatMap { rules[$0] }
            let projection = ScheduleRuleProjection.read(
                scheduleID: id,
                conditionsJSON: rawRule?.conditions,
                actionsJSON: rawRule?.actions
            )
            projectionsByScheduleID[id] = projection
            let nextDateCandidates = nextDates[id] ?? []
            guard nextDateCandidates.count == 1,
                  let occurrenceDate = nextDateCandidates[0].effectiveDate else { continue }
            transactionLowerBounds[id] = scheduleTransactionLowerBound(
                occurrenceDate: occurrenceDate,
                matchingMode: projection.occurrenceMatchingMode,
                postsTransaction: flexibleBool(row["posts_transaction"])
            )
        }
        let transactionDates = try scheduleTransactionDates(
            lowerBoundsByScheduleID: transactionLowerBounds,
            db: db
        )

        var details: [ScheduleDetail] = []
        for row in rows {
            guard let id = row["id"] as String?, !id.isEmpty else { continue }
            let ruleID = row["rule"] as String?
            guard let projection = projectionsByScheduleID[id] else { continue }
            let nextDateCandidates = nextDates[id] ?? []
            let selectedNextDate = nextDateCandidates.count == 1 ? nextDateCandidates[0] : nil
            let effectiveNextDate = selectedNextDate?.effectiveDate
            var reasons = projection.unsupportedReasons
            if nextDateCandidates.isEmpty { reasons.append(.missingNextDate) }
            else if nextDateCandidates.count > 1 { reasons.append(.ambiguousNextDate) }
            else if effectiveNextDate == nil { reasons.append(.missingNextDate) }

            let account = scheduleAccountReference(
                id: projection.accountID,
                facts: accountFacts
            )
            let payee = schedulePayeeReference(
                mappingID: projection.payeeMappingID,
                targets: payeeTargets,
                facts: payeeFacts
            )
            let isCompleted = flexibleBool(row["completed"])
            let postsTransaction = flexibleBool(row["posts_transaction"])
            let upcomingLength = (row["custom_upcoming_length"] as String?) ?? defaultUpcomingLength
            let hasPaidTransaction = effectiveNextDate.map {
                scheduleHasMatchingTransaction(
                    dates: transactionDates[id] ?? [],
                    occurrenceDate: $0,
                    matchingMode: projection.occurrenceMatchingMode,
                    postsTransaction: postsTransaction
                )
            } ?? false
            let status = effectiveNextDate.map {
                ScheduleStatus.resolve(
                    nextDate: $0,
                    completed: isCompleted,
                    hasMatchingTransaction: hasPaidTransaction,
                    today: today,
                    upcomingLength: upcomingLength
                )
            } ?? (isCompleted ? .completed : .scheduled)
            let hasUniqueNextDateRow = selectedNextDate != nil
            let hasEffectiveNextDate = effectiveNextDate != nil && hasUniqueNextDateRow
            let hasUniqueRuleOwner: Bool
            if let ruleID {
                hasUniqueRuleOwner = try !scheduleRuleHasAnotherLiveOwner(
                    ruleID: ruleID,
                    scheduleID: id,
                    db: db
                )
            } else {
                hasUniqueRuleOwner = false
            }
            let canEditMetadata = projection.capabilities.canEditMetadata
                && supportsScheduleMetadataEdit && hasUniqueRuleOwner
            let canEditAccount = projection.capabilities.canEditAccount
                && supportsScheduleRuleEdit && hasUniqueNextDateRow && supportsNextDateWrites
                && selectedNextDate?.baseTimestamp.flatMap(Int64.init) != nil && hasUniqueRuleOwner
            let canEditDate = projection.capabilities.canEditDate
                && supportsScheduleRuleEdit && hasUniqueNextDateRow && supportsNextDateWrites
                && selectedNextDate?.baseTimestamp.flatMap(Int64.init) != nil && hasUniqueRuleOwner
            let canEditPayee = projection.capabilities.canEditPayee && supportsScheduleRuleEdit && hasUniqueRuleOwner
            let canEditAmount = projection.capabilities.canEditAmount && supportsScheduleRuleEdit && hasUniqueRuleOwner
            let capabilities = ScheduleMutationCapabilities(
                canRead: true,
                canEditMetadata: canEditMetadata,
                canEditAccount: canEditAccount,
                canEditPayee: canEditPayee,
                canEditAmount: canEditAmount,
                canEditDate: canEditDate,
                canSkip: projection.capabilities.canSkip && hasEffectiveNextDate
                    && supportsNextDateWrites && selectedNextDate?.baseTimestamp.flatMap(Int64.init) != nil
                    && hasUniqueRuleOwner,
                canComplete: projection.capabilities.canComplete && supportsScheduleCompletion
                    && !isCompleted && hasUniqueRuleOwner,
                canDelete: projection.capabilities.canDelete && supportsScheduleDeletion
                    && supportsScheduleRuleDeletion && hasUniqueRuleOwner,
                canPost: projection.capabilities.canPost && hasEffectiveNextDate
            )
            details.append(
                ScheduleDetail(
                    id: id,
                    ruleID: ruleID,
                    name: row["name"],
                    amount: projection.amount,
                    dateRule: projection.dateRule,
                    account: account,
                    payee: payee,
                    effectiveNextDate: effectiveNextDate,
                    status: status,
                    completed: isCompleted,
                    postsTransaction: postsTransaction,
                    customUpcomingLength: row["custom_upcoming_length"],
                    sortOrder: scheduleColumns.contains("sort_order")
                        ? optionalScheduleDouble(row["sort_order"])
                        : nil,
                    rawConditionsJSON: projection.rawConditionsJSON,
                    rawActionsJSON: projection.rawActionsJSON,
                    capabilities: capabilities,
                    unsupportedReasons: Array(Set(reasons)).sorted { $0.message < $1.message },
                    occurrenceIdentity: ScheduleOccurrenceIdentity(
                        scheduleID: id,
                        nextDateRowID: selectedNextDate?.id,
                        effectiveNextDate: effectiveNextDate,
                        localNextDateTimestamp: selectedNextDate?.localTimestamp,
                        baseNextDateTimestamp: selectedNextDate?.baseTimestamp
                    )
                )
            )
        }

        details.sort { lhs, rhs in
            if lhs.completed != rhs.completed { return !lhs.completed }
            switch (lhs.effectiveNextDate, rhs.effectiveNextDate) {
            case let (left?, right?) where left != right: return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.id < rhs.id
            }
        }
        return LoadedSchedules(
            budgetID: budgetID,
            schedules: details.map(\.summary),
            detailsByID: Dictionary(uniqueKeysWithValues: details.map { ($0.id, $0) }),
            defaultUpcomingLength: defaultUpcomingLength,
            supportsAuthoring: supportsAuthoring
        )
    }

    private struct ScheduleRuleRow {
        let conditions: String?
        let actions: String?
    }

    private struct ScheduleNextDateRow {
        let id: String?
        let localDate: String?
        let localTimestamp: String?
        let baseDate: String?
        let baseTimestamp: String?

        var effectiveDate: String? {
            localTimestamp != nil && localTimestamp == baseTimestamp ? localDate : baseDate
        }
    }

    private struct ScheduleAccountFact {
        let name: String
        let isClosed: Bool
    }

    private func scheduleRuleRows(db: Database) throws -> [String: ScheduleRuleRow] {
        guard try tableExists("rules", db: db) else { return [:] }
        let columns = try columnSet(for: "rules", db: db)
        guard columns.contains("id") else { return [:] }
        let conditions = column("conditions", fallback: "NULL", columns: columns)
        let actions = column("actions", fallback: "NULL", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, \(conditions) AS conditions, \(actions) AS actions
                FROM rules WHERE \(predicateForLiveRows(columns: columns))
                """
        )
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let id = row["id"] as String? else { return nil }
            return (id, ScheduleRuleRow(conditions: row["conditions"], actions: row["actions"]))
        })
    }

    func scheduleRuleHasAnotherLiveOwner(
        ruleID: String,
        scheduleID: String,
        db: Database
    ) throws -> Bool {
        let columns = try requiredColumns(table: "schedules", required: ["id", "rule"], db: db)
        return try Row.fetchOne(
            db,
            sql: """
                SELECT id FROM schedules
                WHERE rule = ? AND id != ? AND \(predicateForLiveRows(columns: columns))
                LIMIT 1
                """,
            arguments: [ruleID, scheduleID]
        ) != nil
    }

    private func scheduleNextDateRows(db: Database) throws -> [String: [ScheduleNextDateRow]] {
        guard try tableExists("schedules_next_date", db: db) else { return [:] }
        let columns = try columnSet(for: "schedules_next_date", db: db)
        guard columns.contains("schedule_id") else { return [:] }
        let id = column("id", fallback: "NULL", columns: columns)
        let localDate = column("local_next_date", fallback: "NULL", columns: columns)
        let localTimestamp = column("local_next_date_ts", fallback: "NULL", columns: columns)
        let baseDate = column("base_next_date", fallback: "NULL", columns: columns)
        let baseTimestamp = column("base_next_date_ts", fallback: "NULL", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(id) AS id, schedule_id,
                       \(localDate) AS local_next_date,
                       \(localTimestamp) AS local_next_date_ts,
                       \(baseDate) AS base_next_date,
                       \(baseTimestamp) AS base_next_date_ts
                FROM schedules_next_date
                WHERE \(predicateForLiveRows(columns: columns))
                """
        )
        var result: [String: [ScheduleNextDateRow]] = [:]
        for row in rows {
            guard let scheduleID = row["schedule_id"] as String? else { continue }
            result[scheduleID, default: []].append(
                ScheduleNextDateRow(
                    id: row["id"],
                    localDate: canonicalScheduleDayID(row["local_next_date"]),
                    localTimestamp: flexibleString(row["local_next_date_ts"]),
                    baseDate: canonicalScheduleDayID(row["base_next_date"]),
                    baseTimestamp: flexibleString(row["base_next_date_ts"])
                )
            )
        }
        return result
    }

    private func scheduleAccountFacts(db: Database) throws -> [String: ScheduleAccountFact] {
        guard try tableExists("accounts", db: db) else { return [:] }
        let columns = try columnSet(for: "accounts", db: db)
        guard columns.contains("id") else { return [:] }
        let name = column("name", fallback: "id", columns: columns)
        let closed = column("closed", fallback: "0", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, \(name) AS name, \(closed) AS closed
                FROM accounts WHERE \(predicateForLiveRows(columns: columns))
                """
        )
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let id = row["id"] as String? else { return nil }
            return (id, ScheduleAccountFact(name: row["name"] ?? id, isClosed: flexibleBool(row["closed"])))
        })
    }

    private func schedulePayeeFacts(db: Database) throws -> [String: String] {
        guard try tableExists("payees", db: db) else { return [:] }
        let columns = try columnSet(for: "payees", db: db)
        guard columns.contains("id") else { return [:] }
        let name = column("name", fallback: "id", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, \(name) AS name FROM payees WHERE \(predicateForLiveRows(columns: columns))"
        )
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let id = row["id"] as String? else { return nil }
            return (id, row["name"] ?? id)
        })
    }

    private func schedulePayeeTargets(db: Database) throws -> [String: String] {
        guard try tableExists("payee_mapping", db: db) else { return [:] }
        let columns = try columnSet(for: "payee_mapping", db: db)
        guard columns.contains("id") else { return [:] }
        let target: String
        if columns.contains("targetId") { target = "targetId" }
        else if columns.contains("target_id") { target = "target_id" }
        else { return [:] }
        let rows = try Row.fetchAll(db, sql: "SELECT id, \(target) AS target_id FROM payee_mapping")
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let id = row["id"] as String?, let target = row["target_id"] as String? else { return nil }
            return (id, target)
        })
    }

    private func scheduleTransactionDates(
        lowerBoundsByScheduleID: [String: String],
        db: Database
    ) throws -> [String: [String]] {
        guard !lowerBoundsByScheduleID.isEmpty else { return [:] }
        guard try tableExists("transactions", db: db) else { return [:] }
        let columns = try columnSet(for: "transactions", db: db)
        guard columns.contains("schedule"), columns.contains("date") else { return [:] }
        let split = transactionSplitQueryExpressions(columns: columns)
        let parentAlias = "schedule_parent"
        var result: [String: [String]] = [:]
        let bounds = lowerBoundsByScheduleID.sorted { $0.key < $1.key }
        let chunkSize = 400
        for start in stride(from: 0, to: bounds.count, by: chunkSize) {
            let chunk = bounds[start..<min(start + chunkSize, bounds.count)]
            let filters = chunk.map { _ in
                "(\(split.qualifiedSchedule) = ? AND \(normalizedDateExpression(split.qualifiedDate)) >= ?)"
            }.joined(separator: " OR ")
            let arguments = StatementArguments(chunk.flatMap { [$0.key, $0.value] })
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(split.qualifiedSchedule) AS schedule,
                           \(normalizedDateExpression(split.qualifiedDate)) AS date
                    FROM transactions t
                    \(split.parentJoin(parentAlias: parentAlias))
                    WHERE \(split.qualifiedSchedule) IS NOT NULL
                      AND \(split.liveEffectivePredicate(parentAlias: parentAlias))
                      AND (\(filters))
                    """,
                arguments: arguments
            )
            for row in rows {
                guard let scheduleID = row["schedule"] as String?,
                      let dayID = canonicalScheduleDayID(row["date"]) else { continue }
                result[scheduleID, default: []].append(dayID)
            }
        }
        return result
    }

    private func scheduleUpcomingLength(db: Database) throws -> String {
        guard try tableExists("preferences", db: db) else { return "7" }
        let columns = try columnSet(for: "preferences", db: db)
        guard columns.contains("id"), columns.contains("value") else { return "7" }
        return try String.fetchOne(
            db,
            sql: "SELECT value FROM preferences WHERE id = 'upcomingScheduledTransactionLength' LIMIT 1"
        ) ?? "7"
    }

    private func scheduleAccountReference(
        id: String?,
        facts: [String: ScheduleAccountFact]
    ) -> ScheduleAccountReference {
        guard let id, let fact = facts[id] else {
            return ScheduleAccountReference(id: id, name: nil, availability: .missing)
        }
        return ScheduleAccountReference(
            id: id,
            name: fact.name,
            availability: fact.isClosed ? .closed : .available
        )
    }

    private func schedulePayeeReference(
        mappingID: String?,
        targets: [String: String],
        facts: [String: String]
    ) -> SchedulePayeeReference {
        guard let mappingID else {
            return SchedulePayeeReference(id: nil, name: nil, isMissing: false)
        }
        guard let targetID = targets[mappingID] else {
            return SchedulePayeeReference(id: mappingID, name: nil, isMissing: true)
        }
        return SchedulePayeeReference(
            id: targetID,
            name: facts[targetID],
            isMissing: facts[targetID] == nil
        )
    }

    private func scheduleHasMatchingTransaction(
        dates: [String],
        occurrenceDate: String,
        matchingMode: ScheduleOccurrenceMatchingMode,
        postsTransaction: Bool
    ) -> Bool {
        let lowerBound = scheduleTransactionLowerBound(
            occurrenceDate: occurrenceDate,
            matchingMode: matchingMode,
            postsTransaction: postsTransaction
        )
        // Pinned Actual's status query uses only this lower bound. Forecast
        // occurrence matching adds an upper bound, but that is a different read.
        return dates.contains { $0 >= lowerBound }
    }

    /// Shared by schedule status reads and schedule-post write validation so
    /// both use Actual's same exact-date / approximate lookback contract.
    func scheduleTransactionLowerBound(
        occurrenceDate: String,
        matchingMode: ScheduleOccurrenceMatchingMode,
        postsTransaction: Bool
    ) -> String {
        if matchingMode == .exact || postsTransaction {
            return occurrenceDate
        }
        guard let occurrence = ActualScheduleRecurrence.date(from: occurrenceDate),
              let earlier = Calendar.actualScheduleGregorian.date(
                byAdding: .day,
                value: -2,
                to: occurrence
              ) else {
            return occurrenceDate
        }
        return ActualScheduleRecurrence.dayID(from: earlier)
    }

    private func canonicalScheduleDayID(_ value: DatabaseValueConvertible?) -> String? {
        guard let raw = flexibleString(value) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let dayID: String
        if trimmed.count == 8, trimmed.allSatisfy(\.isNumber) {
            dayID = "\(trimmed.prefix(4))-\(trimmed.dropFirst(4).prefix(2))-\(trimmed.suffix(2))"
        } else {
            dayID = trimmed
        }
        return ActualScheduleRecurrence.date(from: dayID) == nil ? nil : dayID
    }

    func optionalScheduleDouble(_ value: DatabaseValueConvertible?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Float { return Double(value) }
        if let value = value as? Int { return Double(value) }
        if let value = value as? Int64 { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }
}
