import Foundation
import GRDB

extension BudgetDatabase {
    func fetchRuleEditorOptions() throws -> RuleEditorOptions {
        let accounts = try fetchAccounts()
        let categories = try fetchCategories()
        let payees = try fetchPayees()
        let accountNames = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        let categoryGroups = try queue.read { db -> [RuleEditorChoice] in
            guard try tableExists("category_groups", db: db) else { return [] }
            let columns = try columnSet(for: "category_groups", db: db)
            guard columns.contains("id"), columns.contains("name") else { return [] }
            let order = columns.contains("sort_order") ? "sort_order, lower(name)" : "lower(name)"
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name
                    FROM category_groups
                    WHERE \(predicateForLiveRows(columns: columns))
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

    func previewRules(for draft: TransactionDraft) throws -> TransactionRulePreview {
        let rules = try fetchRules()
        let context = try ruleEvaluationContext(for: draft)
        let result = RuleConditionEvaluator.applying(rules, to: context)
        return TransactionRulePreview(
            categoryID: result.categoryID,
            notes: result.notes,
            accountID: result.accountID == draft.accountID ? nil : result.accountID,
            payeeID: result.payeeID == draft.payeeID ? nil : result.payeeID,
            amountMinorUnits: result.amount == draft.amountMinorUnits ? nil : result.amount,
            date: Calendar.current.isDate(result.date, inSameDayAs: draft.date) ? nil : result.date,
            cleared: result.cleared == draft.cleared ? nil : result.cleared
        )
    }

    func fetchMatchingTransactions(
        for draft: RuleDraft,
        limit: Int
    ) throws -> RuleTransactionMatchPreview {
        guard !draft.conditions.isEmpty else {
            return RuleTransactionMatchPreview(transactions: [], totalCount: 0)
        }

        let transactions = try fetchTransactions()
        let metadata = try ruleEvaluationMetadata()
        let matches = transactions.compactMap { transaction -> RuleTransactionMatch? in
            guard let context = ruleEvaluationContext(for: transaction, metadata: metadata),
                  RuleConditionEvaluator.conditionsMatch(draft, context: context),
                  let id = transaction.id else { return nil }
            let isTransfer = transaction.payee.map { metadata.transferPayeeIDs.contains($0) } ?? false
            let categoryName: String
            if let categoryID = transaction.category {
                categoryName = metadata.categoryNames[categoryID] ?? "Deleted category"
            } else {
                categoryName = isTransfer ? "Account Transfer" : "Uncategorized"
            }
            return RuleTransactionMatch(
                id: id,
                date: transaction.date,
                payeeName: transaction.payeeName
                    ?? transaction.payee.flatMap { metadata.payeeNames[$0] }
                    ?? transaction.importedPayee
                    ?? "Unknown payee",
                categoryName: categoryName,
                accountName: metadata.accountNames[transaction.account] ?? "Deleted account",
                amountMinorUnits: transaction.amount ?? 0
            )
        }

        return RuleTransactionMatchPreview(
            transactions: Array(matches.prefix(max(0, limit))),
            totalCount: matches.count
        )
    }

    func fetchRules() throws -> [ManagedRule] {
        try queue.read { db in
            guard try tableExists("rules", db: db) else { return [] }
            let columns = try columnSet(for: "rules", db: db)
            guard columns.isSuperset(of: ["id", "conditions", "actions"]) else { return [] }
            let stageColumn = columns.contains("stage") ? "stage" : "NULL"
            let joinColumn = columns.contains("conditions_op") ? "conditions_op" : "'and'"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, \(stageColumn) AS stage, conditions, actions,
                           \(joinColumn) AS conditions_op
                    FROM rules
                    WHERE \(predicateForLiveRows(columns: columns))
                    """
            )
            let completedScheduleRuleIDs = try completedScheduleRuleIDs(db: db)
            let payeeTargets = try payeeMappingTargets(db: db)
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
                    isCompletedScheduleRule: completedScheduleRuleIDs.contains(id)
                )
            }
            .sorted { lhs, rhs in
                let lhsStage = lhs.draft?.stage ?? .normal
                let rhsStage = rhs.draft?.stage ?? .normal
                let order: [RuleStage: Int] = [.pre: 0, .normal: 1, .post: 2]
                if lhsStage != rhsStage { return order[lhsStage, default: 1] < order[rhsStage, default: 1] }
                return lhs.id < rhs.id
            }
        }
    }

    func createRuleMessages(
        ruleID: String,
        draft: RuleDraft,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            let columns = try requiredColumns(
                table: "rules",
                required: ["conditions", "actions"],
                db: db
            )
            var messages = try ruleMessages(ruleID: ruleID, draft: draft, columns: columns, builder: &builder)
            if columns.contains("tombstone") {
                messages.append(try builder.makeMessage(
                    dataset: "rules", row: ruleID, column: "tombstone", value: .bool(false)
                ))
            }
            return messages
        }
    }

    func updateRuleMessages(
        ruleID: String,
        draft: RuleDraft,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            let columns = try requiredColumns(
                table: "rules",
                required: ["conditions", "actions"],
                db: db
            )
            guard try rowExists(table: "rules", rowID: ruleID, db: db) else {
                throw LocalFirstError.invalidLocalWrite("rule no longer exists")
            }
            return try ruleMessages(ruleID: ruleID, draft: draft, columns: columns, builder: &builder)
        }
    }

    func deleteRuleMessages(
        ruleID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            _ = try requiredColumns(table: "rules", required: ["tombstone"], db: db)
            guard try rowExists(table: "rules", rowID: ruleID, db: db) else {
                throw LocalFirstError.invalidLocalWrite("rule no longer exists")
            }
            return [try builder.makeMessage(
                dataset: "rules", row: ruleID, column: "tombstone", value: .bool(true)
            )]
        }
    }

    func categoryLearningRuleMessages(
        changedTransactionIDs: Set<String>,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard !changedTransactionIDs.isEmpty else { return [] }
        let rules = try fetchRules()
        return try queue.read { db in
            guard try globalCategoryLearningEnabled(db: db),
                  try tableExists("transactions", db: db),
                  try tableExists("payees", db: db),
                  try tableExists("rules", db: db) else { return [] }
            let transactionColumns = try columnSet(for: "transactions", db: db)
            guard transactionColumns.contains("id"), transactionColumns.contains("date"),
                  transactionColumns.contains("category"),
                  let payeeColumn = ["description", "payee"].first(where: transactionColumns.contains) else {
                return []
            }
            let payeeColumns = try columnSet(for: "payees", db: db)
            guard payeeColumns.contains("learn_categories") else { return [] }
            let placeholders = Array(repeating: "?", count: changedTransactionIDs.count).joined(separator: ",")
            let changedRows = try Row.fetchAll(
                db,
                sql: "SELECT id, date, \(quotedIdentifier(payeeColumn)) AS payee_id FROM transactions WHERE id IN (\(placeholders))",
                arguments: StatementArguments(Array(changedTransactionIDs))
            )
            let mappingTargets = try payeeMappingTargets(db: db)
            let changedPayeeIDs = Set(changedRows.compactMap { row -> String? in
                guard let rawPayeeID = row["payee_id"] as String? else { return nil }
                return mappingTargets[rawPayeeID] ?? rawPayeeID
            })
            guard !changedPayeeIDs.isEmpty else { return [] }
            let oldestDate = changedRows.compactMap { normalizedDateString($0["date"]) }.min() ?? "1970-01-01"
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            let oldest = formatter.date(from: oldestDate) ?? Date(timeIntervalSince1970: 0)
            let lowerBound = formatter.string(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: -180, to: oldest) ?? oldest)
            let upperBound = formatter.string(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: 180, to: Date()) ?? Date())
            let payeePlaceholders = Array(repeating: "?", count: changedPayeeIDs.count).joined(separator: ",")
            let parentPredicate: String
            if transactionColumns.contains("is_parent") { parentPredicate = "AND (t.is_parent = 0 OR t.is_parent IS NULL)" }
            else if transactionColumns.contains("isParent") { parentPredicate = "AND (t.isParent = 0 OR t.isParent IS NULL)" }
            else { parentPredicate = "" }
            let rawPayee = "t.\(quotedIdentifier(payeeColumn))"
            var resolvedPayee = rawPayee
            var mappingJoin = ""
            if try tableExists("payee_mapping", db: db) {
                let mappingColumns = try columnSet(for: "payee_mapping", db: db)
                let target = mappingColumns.contains("targetId") ? "targetId" : mappingColumns.contains("target_id") ? "target_id" : nil
                if mappingColumns.contains("id"), let target {
                    mappingJoin = "LEFT JOIN payee_mapping pm ON pm.id = \(rawPayee)"
                    resolvedPayee = "COALESCE(pm.\(quotedIdentifier(target)), \(rawPayee))"
                }
            }
            var accountJoin = ""
            var openAccountPredicate = ""
            if let accountColumn = ["acct", "account"].first(where: transactionColumns.contains),
               try tableExists("accounts", db: db) {
                let accountColumns = try columnSet(for: "accounts", db: db)
                if accountColumns.contains("id"), accountColumns.contains("closed") {
                    accountJoin = "LEFT JOIN accounts a ON a.id = t.\(quotedIdentifier(accountColumn))"
                    openAccountPredicate = "AND (a.closed = 0 OR a.closed IS NULL)"
                }
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT t.id, \(normalizedDateExpression("t.date")) AS date, t.category,
                           \(resolvedPayee) AS payee_id
                    FROM transactions t
                    \(mappingJoin)
                    \(accountJoin)
                    JOIN payees p ON p.id = \(resolvedPayee)
                    WHERE \(predicateForLiveRows(columns: transactionColumns).replacingOccurrences(of: "tombstone", with: "t.tombstone"))
                      AND \(normalizedDateExpression("t.date")) >= ?
                      AND \(normalizedDateExpression("t.date")) <= ?
                      AND \(resolvedPayee) IN (\(payeePlaceholders))
                      AND p.learn_categories = 1
                      \(openAccountPredicate)
                      \(parentPredicate)
                    ORDER BY \(normalizedDateExpression("t.date")) DESC
                    """,
                arguments: StatementArguments([lowerBound, upperBound] + Array(changedPayeeIDs))
            )
            let changedIDSet = changedTransactionIDs
            let grouped = Dictionary(grouping: rows) { $0["payee_id"] as String? ?? "" }
            let ruleColumns = try columnSet(for: "rules", db: db)
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
    }

    private func ruleMessages(
        ruleID: String,
        draft: RuleDraft,
        columns: Set<String>,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard draft.canRoundTripAndEvaluate else {
            throw LocalFirstError.invalidLocalWrite("this rule contains fields Actualist cannot safely evaluate")
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

    private func ruleJSONHasOnlyKnownKeys(_ json: String, kind: RuleJSONKind) -> Bool {
        guard let data = json.data(using: .utf8),
              let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return false
        }
        return objects.allSatisfy { Set($0.keys).isSubset(of: kind.allowedKeys) }
    }

    private struct RuleEvaluationMetadata {
        let accountNames: [String: String]
        let offBudgetAccountIDs: Set<String>
        let categoryNames: [String: String]
        let categoryGroupsByCategoryID: [String: String]
        let categoryGroupNames: [String: String]
        let payeeNames: [String: String]
        let transferPayeeIDs: Set<String>
    }

    private func ruleEvaluationMetadata() throws -> RuleEvaluationMetadata {
        try queue.read { db in
            var accountNames: [String: String] = [:]
            var offBudgetAccountIDs = Set<String>()
            if try tableExists("accounts", db: db) {
                let columns = try columnSet(for: "accounts", db: db)
                let name = columns.contains("name") ? "name" : "''"
                let offbudget = columns.contains("offbudget") ? "offbudget" : "0"
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, \(name) AS name, \(offbudget) AS offbudget FROM accounts"
                )
                for row in rows {
                    guard let id = row["id"] as String? else { continue }
                    accountNames[id] = row["name"] ?? ""
                    if flexibleBool(row["offbudget"]) { offBudgetAccountIDs.insert(id) }
                }
            }
            var categoryNames: [String: String] = [:]
            var categoryGroupsByCategoryID: [String: String] = [:]
            var categoryGroupNames: [String: String] = [:]
            if try tableExists("category_groups", db: db) {
                let rows = try Row.fetchAll(db, sql: "SELECT id, name FROM category_groups")
                categoryGroupNames = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                    guard let id = row["id"] as String? else { return nil }
                    return (id, row["name"] as String? ?? "")
                })
            }
            if try tableExists("categories", db: db) {
                let columns = try columnSet(for: "categories", db: db)
                let group = columns.contains("cat_group") ? "cat_group" : columns.contains("group_id") ? "group_id" : nil
                let groupSelection = group.map { "\(quotedIdentifier($0)) AS group_id" } ?? "NULL AS group_id"
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, name, \(groupSelection) FROM categories"
                )
                for row in rows {
                    guard let id = row["id"] as String? else { continue }
                    categoryNames[id] = row["name"] ?? ""
                    if let groupID = row["group_id"] as String? {
                        categoryGroupsByCategoryID[id] = groupID
                    }
                }
            }
            var payeeNames: [String: String] = [:]
            var transferPayeeIDs = Set<String>()
            if try tableExists("payees", db: db) {
                let columns = try columnSet(for: "payees", db: db)
                let transferAccount = columns.contains("transfer_acct") ? "transfer_acct" : "NULL"
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, name, \(transferAccount) AS transfer_account FROM payees"
                )
                for row in rows {
                    guard let id = row["id"] as String? else { continue }
                    let transferAccountID = row["transfer_account"] as String?
                    if transferAccountID != nil { transferPayeeIDs.insert(id) }
                    let rawName = row["name"] as String? ?? ""
                    payeeNames[id] = rawName.isEmpty
                        ? transferAccountID.flatMap { accountNames[$0] } ?? ""
                        : rawName
                }
            }
            return RuleEvaluationMetadata(
                accountNames: accountNames,
                offBudgetAccountIDs: offBudgetAccountIDs,
                categoryNames: categoryNames,
                categoryGroupsByCategoryID: categoryGroupsByCategoryID,
                categoryGroupNames: categoryGroupNames,
                payeeNames: payeeNames,
                transferPayeeIDs: transferPayeeIDs
            )
        }
    }

    private func ruleEvaluationContext(for draft: TransactionDraft) throws -> RuleEvaluationContext {
        let metadata = try ruleEvaluationMetadata()
        let categoryGroupID = draft.categoryID.flatMap { metadata.categoryGroupsByCategoryID[$0] }
        return RuleEvaluationContext(
            accountID: draft.accountID,
            accountName: metadata.accountNames[draft.accountID] ?? "",
            accountIsOffBudget: metadata.offBudgetAccountIDs.contains(draft.accountID),
            amount: draft.amountMinorUnits,
            categoryID: draft.categoryID,
            categoryName: draft.categoryID.flatMap { metadata.categoryNames[$0] },
            categoryGroupID: categoryGroupID,
            categoryGroupName: categoryGroupID.flatMap { metadata.categoryGroupNames[$0] },
            date: draft.date,
            notes: draft.notes,
            payeeID: draft.payeeID,
            payeeName: draft.payeeName,
            importedPayee: draft.importedPayee,
            cleared: draft.cleared,
            reconciled: draft.reconciled,
            isTransfer: draft.isTransfer,
            isParent: draft.isParent,
            accountNames: metadata.accountNames,
            offBudgetAccountIDs: metadata.offBudgetAccountIDs,
            categoryNames: metadata.categoryNames,
            categoryGroupsByCategoryID: metadata.categoryGroupsByCategoryID,
            categoryGroupNames: metadata.categoryGroupNames,
            payeeNames: metadata.payeeNames
        )
    }

    private func ruleEvaluationContext(
        for transaction: ActualTransaction,
        metadata: RuleEvaluationMetadata
    ) -> RuleEvaluationContext? {
        guard let date = Self.rulePreviewDateFormatter.date(from: transaction.date) else { return nil }
        let categoryGroupID = transaction.category.flatMap { metadata.categoryGroupsByCategoryID[$0] }
        return RuleEvaluationContext(
            accountID: transaction.account,
            accountName: metadata.accountNames[transaction.account] ?? "",
            accountIsOffBudget: metadata.offBudgetAccountIDs.contains(transaction.account),
            amount: transaction.amount ?? 0,
            categoryID: transaction.category,
            categoryName: transaction.category.flatMap { metadata.categoryNames[$0] },
            categoryGroupID: categoryGroupID,
            categoryGroupName: categoryGroupID.flatMap { metadata.categoryGroupNames[$0] },
            date: date,
            notes: transaction.notes,
            payeeID: transaction.payee,
            payeeName: transaction.payeeName
                ?? transaction.payee.flatMap { metadata.payeeNames[$0] }
                ?? "",
            importedPayee: transaction.importedPayee,
            cleared: transaction.cleared?.boolValue == true,
            reconciled: transaction.reconciled,
            isTransfer: transaction.payee.map { metadata.transferPayeeIDs.contains($0) } ?? false,
            isParent: transaction.isParent,
            accountNames: metadata.accountNames,
            offBudgetAccountIDs: metadata.offBudgetAccountIDs,
            categoryNames: metadata.categoryNames,
            categoryGroupsByCategoryID: metadata.categoryGroupsByCategoryID,
            categoryGroupNames: metadata.categoryGroupNames,
            payeeNames: metadata.payeeNames
        )
    }

    private static let rulePreviewDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    private func completedScheduleRuleIDs(db: Database) throws -> Set<String> {
        guard try tableExists("schedules", db: db) else { return [] }
        let columns = try columnSet(for: "schedules", db: db)
        guard columns.contains("rule"), columns.contains("completed") else { return [] }
        let ids = try String.fetchAll(
            db,
            sql: "SELECT rule FROM schedules WHERE completed = 1 AND rule IS NOT NULL AND \(predicateForLiveRows(columns: columns))"
        )
        return Set(ids)
    }

    private func globalCategoryLearningEnabled(db: Database) throws -> Bool {
        guard try tableExists("preferences", db: db) else { return true }
        let columns = try columnSet(for: "preferences", db: db)
        guard columns.contains("id"), columns.contains("value") else { return true }
        let value = try String.fetchOne(db, sql: "SELECT value FROM preferences WHERE id = 'learn-categories' LIMIT 1")
        return value != "false"
    }

    private func normalizedDateString(_ value: DatabaseValueConvertible?) -> String? {
        if let string = value as? String { return String(string.prefix(10)) }
        if let int = value as? Int {
            let text = String(format: "%08d", int)
            return "\(text.prefix(4))-\(text.dropFirst(4).prefix(2))-\(text.suffix(2))"
        }
        if let int = value as? Int64 {
            return normalizedDateString(Int(int))
        }
        return nil
    }

    private func payeeMappingTargets(db: Database) throws -> [String: String] {
        guard try tableExists("payee_mapping", db: db) else { return [:] }
        let columns = try columnSet(for: "payee_mapping", db: db)
        guard columns.contains("id") else { return [:] }
        let target = columns.contains("targetId") ? "targetId" : columns.contains("target_id") ? "target_id" : nil
        guard let target else { return [:] }
        let rows = try Row.fetchAll(db, sql: "SELECT id, \(quotedIdentifier(target)) AS target_id FROM payee_mapping")
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let id = row["id"] as String?, let targetID = row["target_id"] as String? else { return nil }
            return (id, targetID)
        })
    }

    private func conditionByResolvingPayeeMappings(
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

    private func payeeIDs(in jsonStrings: [String]) -> Set<String> {
        var result = Set<String>()
        for json in jsonStrings {
            guard let data = json.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) else { continue }
            collectPayeeIDs(in: value, result: &result)
        }
        return result
    }

    private func collectPayeeIDs(in value: Any, result: inout Set<String>) {
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

    private func collectStringValues(in value: Any?, result: inout Set<String>) {
        if let string = value as? String { result.insert(string) }
        else if let array = value as? [Any] {
            for nested in array { collectStringValues(in: nested, result: &result) }
        } else if let object = value as? [String: Any] {
            for nested in object.values { collectStringValues(in: nested, result: &result) }
        }
    }
}
