import Foundation
import GRDB

enum RuleSQL {
    static func fetchRuleEditorOptions(in database: isolated BudgetDatabase) throws -> RuleEditorOptions {
        let accounts = try database.fetchAccounts()
        let categories = try database.fetchCategories()
        let payees = try database.fetchPayees()
        let accountNames = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        let categoryGroups = try database.queue.read { db -> [RuleEditorChoice] in
            guard try database.tableExists("category_groups", db: db) else { return [] }
            let columns = try database.columnSet(for: "category_groups", db: db)
            guard columns.contains("id"), columns.contains("name") else { return [] }
            let order = columns.contains("sort_order") ? "sort_order, lower(name)" : "lower(name)"
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name
                    FROM category_groups
                    WHERE \(database.predicateForLiveRows(columns: columns))
                    ORDER BY \(order)
                    """
            ).compactMap { row in
                guard let id = row["id"] as String? else { return nil }
                return RuleEditorChoice(id: id, name: row["name"] ?? "")
            }
        }
        return RuleEditorOptions(
            accounts: accounts.map { RuleEditorChoice(id: $0.id, name: $0.name) },
            categories: categories.compactMap { category in
                category.id.map {
                    RuleEditorChoice(id: $0, name: category.name.actualistCategoryNameParts.name)
                }
            },
            categoryGroups: categoryGroups,
            payees: payees.compactMap { payee in
                payee.id.map {
                    RuleEditorChoice(
                        id: $0,
                        name: payee.name.isEmpty
                            ? payee.transferAccount.flatMap { accountNames[$0] } ?? "Unknown payee"
                            : payee.name,
                        isTransfer: payee.transferAccount != nil
                    )
                }
            }
        )
    }

    static func fetchRules(in database: isolated BudgetDatabase) throws -> [ManagedRule] {
        try database.queue.read { db in
            try fetchRules(in: database, db: db)
        }
    }

    static func fetchRules(in database: isolated BudgetDatabase, db: Database) throws -> [ManagedRule] {
        guard try database.tableExists("rules", db: db) else { return [] }
        let columns = try database.columnSet(for: "rules", db: db)
        guard columns.isSuperset(of: ["id", "conditions", "actions"]) else { return [] }
        let stageColumn = columns.contains("stage") ? "stage" : "NULL"
        let joinColumn = columns.contains("conditions_op") ? "conditions_op" : "'and'"
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, \(stageColumn) AS stage, conditions, actions,
                       \(joinColumn) AS conditions_op
                FROM rules
                WHERE \(database.predicateForLiveRows(columns: columns))
                """
        )
        let scheduleIndex = try ScheduleSQL.fetchRuleScheduleIndex(in: database, db: db)
        let completedScheduleRuleIDs = scheduleIndex.completedRuleIDs
        let payeeTargets = try payeeMappingTargets(in: database, db: db)
        let decoder = JSONDecoder()

        return rows.compactMap { row in
            guard let id = row["id"] as String? else { return nil }
            let rawStage = row["stage"] as String?
            let rawConditions = row["conditions"] as String? ?? "[]"
            let rawActions = row["actions"] as String? ?? "[]"
            let join = RuleConditionJoin(rawValue: row["conditions_op"] as String? ?? "and") ?? .and
            let stage = rawStage.flatMap(RuleStage.init(rawValue:)) ?? .normal
            let conditions = rawConditions.data(using: .utf8).flatMap {
                try? decoder.decode([RuleCondition].self, from: $0)
            }
            let actions = rawActions.data(using: .utf8).flatMap {
                try? decoder.decode([RuleAction].self, from: $0)
            }
            let mappedConditions = conditions.map { conditions in
                conditions.map { conditionByResolvingPayeeMappings($0, targets: payeeTargets) }
            }
            let decodedDraft = mappedConditions.flatMap { conditions in
                actions.map { actions in
                    RuleDraft(stage: stage, conditionsJoin: join, conditions: conditions, actions: actions)
                }
            }
            let hasOnlyKnownKeys = ruleJSONHasOnlyKnownKeys(rawConditions, kind: .condition)
                && ruleJSONHasOnlyKnownKeys(rawActions, kind: .action)
                && (rawStage == nil || RuleStage(rawValue: rawStage ?? "") != nil)
                && RuleConditionJoin(rawValue: row["conditions_op"] as String? ?? "and") != nil
            let draft = decodedDraft.flatMap {
                hasOnlyKnownKeys && $0.canRoundTripAndEvaluate ? $0 : nil
            }
            return ManagedRule(
                id: id,
                draft: draft,
                rawStage: rawStage,
                rawConditionsJSON: rawConditions,
                rawActionsJSON: rawActions,
                payeeIDs: Set(payeeIDs(in: [rawConditions, rawActions]).map { payeeTargets[$0] ?? $0 }),
                isCompletedScheduleRule: completedScheduleRuleIDs.contains(id),
                rawConditionsJoin: row["conditions_op"] as String?
            )
        }
        .rankedForExecution()
    }

    static func createRuleMessages(
        ruleID: String,
        draft: RuleDraft,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        try database.queue.read { db in
            let columns = try database.requiredColumns(
                table: "rules",
                required: ["conditions", "actions"],
                db: db
            )
            var messages = try ruleMessages(ruleID: ruleID, draft: draft, columns: columns, builder: &builder)
            if columns.contains("tombstone") {
                messages.append(try builder.revive(dataset: "rules", row: ruleID))
            }
            return messages
        }
    }

    static func updateRuleMessages(
        ruleID: String,
        draft: RuleDraft,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        try database.queue.read { db in
            let columns = try database.requiredColumns(
                table: "rules",
                required: ["conditions", "actions"],
                db: db
            )
            guard try database.rowExists(table: "rules", rowID: ruleID, db: db) else {
                throw LocalFirstError.invalidLocalWrite("rule no longer exists")
            }
            return try ruleMessages(ruleID: ruleID, draft: draft, columns: columns, builder: &builder)
        }
    }

    static func deleteRuleMessages(
        ruleID: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        try database.queue.read { db in
            _ = try database.requiredColumns(table: "rules", required: ["tombstone"], db: db)
            guard try database.rowExists(table: "rules", rowID: ruleID, db: db) else {
                throw LocalFirstError.invalidLocalWrite("rule no longer exists")
            }
            return [try builder.tombstone(dataset: "rules", row: ruleID)]
        }
    }

    static func categoryLearningRuleMessages(
        changedTransactionIDs: Set<String>,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        guard !changedTransactionIDs.isEmpty else { return [] }
        guard try globalCategoryLearningEnabled(in: database, db: db),
                  try database.tableExists("transactions", db: db),
                  try database.tableExists("payees", db: db),
                  try database.tableExists("rules", db: db) else { return [] }
            let rules = try fetchRules(in: database, db: db)
            let transactionColumns = try database.columnSet(for: "transactions", db: db)
            guard transactionColumns.contains("id"), transactionColumns.contains("date"),
                  transactionColumns.contains("category"),
                  let payeeColumn = TransactionRowColumns.payee(in: transactionColumns) else {
                return []
            }
            let payeeColumns = try database.columnSet(for: "payees", db: db)
            guard payeeColumns.contains("learn_categories") else { return [] }
            let placeholders = Array(repeating: "?", count: changedTransactionIDs.count).joined(separator: ",")
            let changedRows = try Row.fetchAll(
                db,
                sql: "SELECT id, date, \(database.quotedIdentifier(payeeColumn)) AS payee_id FROM transactions WHERE id IN (\(placeholders))",
                arguments: StatementArguments(Array(changedTransactionIDs))
            )
            let mappingTargets = try payeeMappingTargets(in: database, db: db)
            let changedPayeeIDs = Set(changedRows.compactMap { row -> String? in
                guard let rawPayeeID = row["payee_id"] as String? else { return nil }
                return mappingTargets[rawPayeeID] ?? rawPayeeID
            })
            guard !changedPayeeIDs.isEmpty else { return [] }
            let oldestDate = changedRows.compactMap { normalizedDateString($0["date"]) }.min() ?? "1970-01-01"
            let (lowerBound, upperBound) = Self.categoryLearningWindow(oldestDate: oldestDate)
            let payeePlaceholders = Array(repeating: "?", count: changedPayeeIDs.count).joined(separator: ",")
            let parentPredicate: String
            if transactionColumns.contains("is_parent") { parentPredicate = "AND (t.is_parent = 0 OR t.is_parent IS NULL)" }
            else if transactionColumns.contains("isParent") { parentPredicate = "AND (t.isParent = 0 OR t.isParent IS NULL)" }
            else { parentPredicate = "" }
            let rawPayee = "t.\(database.quotedIdentifier(payeeColumn))"
            var resolvedPayee = rawPayee
            var mappingJoin = ""
            if try database.tableExists("payee_mapping", db: db) {
                let mappingColumns = try database.columnSet(for: "payee_mapping", db: db)
                let target = mappingColumns.contains("targetId") ? "targetId" : mappingColumns.contains("target_id") ? "target_id" : nil
                if mappingColumns.contains("id"), let target {
                    mappingJoin = "LEFT JOIN payee_mapping pm ON pm.id = \(rawPayee)"
                    resolvedPayee = "COALESCE(pm.\(database.quotedIdentifier(target)), \(rawPayee))"
                }
            }
            var accountJoin = ""
            var openAccountPredicate = ""
            if let accountColumn = TransactionRowColumns.account(in: transactionColumns),
               try database.tableExists("accounts", db: db) {
                let accountColumns = try database.columnSet(for: "accounts", db: db)
                if accountColumns.contains("id"), accountColumns.contains("closed") {
                    accountJoin = "LEFT JOIN accounts a ON a.id = t.\(database.quotedIdentifier(accountColumn))"
                    openAccountPredicate = "AND (a.closed = 0 OR a.closed IS NULL)"
                }
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT t.id, \(database.normalizedDateExpression("t.date")) AS date, t.category,
                           \(resolvedPayee) AS payee_id
                    FROM transactions t
                    \(mappingJoin)
                    \(accountJoin)
                    JOIN payees p ON p.id = \(resolvedPayee)
                    WHERE \(database.predicateForLiveRows(columns: transactionColumns, tableAlias: "t"))
                      AND \(database.normalizedDateExpression("t.date")) >= ?
                      AND \(database.normalizedDateExpression("t.date")) <= ?
                      AND \(resolvedPayee) IN (\(payeePlaceholders))
                      AND p.learn_categories = 1
                      \(openAccountPredicate)
                      \(parentPredicate)
                    ORDER BY \(database.normalizedDateExpression("t.date")) DESC
                    """,
                arguments: StatementArguments([lowerBound, upperBound] + Array(changedPayeeIDs))
            )
            let changedIDSet = changedTransactionIDs
            let grouped = Dictionary(grouping: rows) { $0["payee_id"] as String? ?? "" }
            let ruleColumns = try database.columnSet(for: "rules", db: db)
            var messages: [ActualSyncDecodedMessage] = []

            for (payeeID, allRows) in grouped where !payeeID.isEmpty {
                let latest = Array(allRows.prefix(5))
                guard latest.contains(where: { row in
                    (row["id"] as String?).map(changedIDSet.contains) == true
                }) else { continue }
                let categories = latest.compactMap { $0["category"] as String? }
                let counts = Dictionary(grouping: categories, by: { $0 }).mapValues(\.count)
                guard let categoryID = categories.first(where: { counts[$0, default: 0] >= 3 }) else { continue }
                let setters = rules.filter { rule in
                    guard let draft = rule.draft,
                          draft.conditions.count == 1,
                          let condition = draft.conditions.first,
                          ["payee", "description"].contains(condition.field), condition.operation == "is",
                          condition.value == .string(payeeID),
                          let action = draft.actions.first,
                          action.operation == "set", action.field == "category" else { return false }
                    return true
                }
                if setters.isEmpty {
                    let newDraft = RuleDraft(
                        stage: .normal,
                        conditionsJoin: .and,
                        conditions: [RuleCondition(field: "description", operation: "is", value: .string(payeeID))],
                        actions: [RuleAction(operation: "set", field: "category", value: .string(categoryID))]
                    )
                    messages += try ruleMessages(
                        ruleID: UUID().uuidString,
                        draft: newDraft,
                        columns: ruleColumns,
                        builder: &builder
                    )
                } else {
                    for setter in setters {
                        guard var updated = setter.draft else { continue }
                        if updated.actions[0].value == .string(categoryID) { continue }
                        updated.actions[0].value = .string(categoryID)
                        messages += try ruleMessages(
                            ruleID: setter.id,
                            draft: updated,
                            columns: ruleColumns,
                            builder: &builder
                        )
                    }
                }
            }
            return messages
    }

    private static func ruleMessages(
        ruleID: String,
        draft: RuleDraft,
        columns: Set<String>,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard draft.canRoundTripAndEvaluate else {
            throw LocalFirstError.refusedChange("This rule uses fields Actualist cannot check yet.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let conditions = String(data: try encoder.encode(draft.conditions), encoding: .utf8) ?? "[]"
        let actions = String(data: try encoder.encode(draft.actions), encoding: .utf8) ?? "[]"
        var messages = [
            try builder.makeMessage(dataset: "rules", row: ruleID, column: "conditions", value: .string(conditions)),
            try builder.makeMessage(dataset: "rules", row: ruleID, column: "actions", value: .string(actions))
        ]
        if columns.contains("stage") {
            messages.append(try builder.makeMessage(
                dataset: "rules",
                row: ruleID,
                column: "stage",
                value: draft.stage.databaseValue.map(LocalFirstSyncValue.string) ?? .null
            ))
        }
        if columns.contains("conditions_op") {
            messages.append(try builder.makeMessage(
                dataset: "rules", row: ruleID, column: "conditions_op", value: .string(draft.conditionsJoin.rawValue)
            ))
        }
        return messages
    }

    private enum RuleJSONKind {
        case condition
        case action

        var allowedKeys: Set<String> {
            switch self {
            case .condition: ["field", "op", "value", "type", "options"]
            case .action: ["op", "field", "value", "type", "options"]
            }
        }
    }

    private static func ruleJSONHasOnlyKnownKeys(_ json: String, kind: RuleJSONKind) -> Bool {
        guard let data = json.data(using: .utf8),
              let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return false
        }
        return objects.allSatisfy { Set($0.keys).isSubset(of: kind.allowedKeys) }
    }

    private static func globalCategoryLearningEnabled(in database: isolated BudgetDatabase, db: Database) throws -> Bool {
        try SyncedPreferences.value(.learnCategories, in: database, db: db) != "false"
    }

    /// Payee category learning reads 180 days before the oldest changed
    /// transaction and 180 days after today (`updateCategoryLearning`,
    /// transaction-rules.ts). Both ends are day arithmetic and today is the
    /// local day, as `currentDay()`. An unreadable oldest day counts as the epoch.
    static func categoryLearningWindow(
        oldestDate: String,
        now: Date = Date(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> (lower: String, upper: String) {
        let epoch = "1970-01-01"
        let oldest = ActualDateOnly.shiftedDayID(oldestDate, byDays: 0) == nil ? epoch : oldestDate
        let today = ActualDateOnly.today(now: now, timeZone: timeZone)
        return (
            ActualDateOnly.shiftedDayID(oldest, byDays: -180) ?? oldest,
            ActualDateOnly.shiftedDayID(today, byDays: 180) ?? today
        )
    }

    private static func normalizedDateString(_ value: DatabaseValueConvertible?) -> String? {
        if let string = value as? String { return String(string.prefix(10)) }
        if let int = value as? Int { return PackedDate.paddedISO(int) }
        if let int = value as? Int64 {
            return normalizedDateString(Int(int))
        }
        return nil
    }

    static func payeeMappingTargets(in database: isolated BudgetDatabase, db: Database) throws -> [String: String] {
        guard try database.tableExists("payee_mapping", db: db) else { return [:] }
        let columns = try database.columnSet(for: "payee_mapping", db: db)
        guard columns.contains("id") else { return [:] }
        let target = columns.contains("targetId") ? "targetId" : columns.contains("target_id") ? "target_id" : nil
        guard let target else { return [:] }
        let rows = try Row.fetchAll(db, sql: "SELECT id, \(database.quotedIdentifier(target)) AS target_id FROM payee_mapping")
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let id = row["id"] as String?, let targetID = row["target_id"] as String? else { return nil }
            return (id, targetID)
        })
    }

    private static func conditionByResolvingPayeeMappings(
        _ condition: RuleCondition,
        targets: [String: String]
    ) -> RuleCondition {
        guard ["payee", "description"].contains(condition.field),
              condition.type == nil || condition.type == RuleCondition.ValueKind.id.rawValue else {
            return condition
        }
        var resolved = condition
        switch condition.operation {
        case "is", "isNot":
            if case .string(let value) = condition.value {
                resolved.value = .string(targets[value] ?? value)
            }
        case "oneOf", "notOneOf":
            if case .array(let values) = condition.value {
                resolved.value = .array(values.map { value in
                    guard case .string(let id) = value else { return value }
                    return .string(targets[id] ?? id)
                })
            }
        default: break
        }
        return resolved
    }

    private static func payeeIDs(in jsonStrings: [String]) -> Set<String> {
        var result = Set<String>()
        for json in jsonStrings {
            guard let data = json.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) else { continue }
            collectPayeeIDs(in: value, result: &result)
        }
        return result
    }

    private static func collectPayeeIDs(in value: Any, result: inout Set<String>) {
        if let object = value as? [String: Any] {
            let field = object["field"] as? String
            if field == "payee" || field == "description" {
                collectStringValues(in: object["value"], result: &result)
            }
            for nested in object.values { collectPayeeIDs(in: nested, result: &result) }
        } else if let array = value as? [Any] {
            for nested in array { collectPayeeIDs(in: nested, result: &result) }
        }
    }

    private static func collectStringValues(in value: Any?, result: inout Set<String>) {
        if let string = value as? String { result.insert(string) }
        else if let array = value as? [Any] {
            for nested in array { collectStringValues(in: nested, result: &result) }
        } else if let object = value as? [String: Any] {
            for nested in object.values { collectStringValues(in: nested, result: &result) }
        }
    }
}
