import Foundation
import GRDB

extension BudgetDatabase {
    func fetchPayeeManagementSnapshot() throws -> PayeeManagementSnapshot {
        try queue.read { db in
            guard try tableExists("payees", db: db) else {
                return .empty
            }
            let payeeColumns = try columnSet(for: "payees", db: db)
            guard payeeColumns.contains("id"), payeeColumns.contains("name") else {
                return .empty
            }
            return try fetchPayeeManagementSnapshot(in: db)
        }
    }

    func createPayeeMessages(
        name: String,
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedName = try validatedPayeeName(name)
        return try queue.read { db in
            let columns = try requiredColumns(table: "payees", required: ["name"], db: db)
            try rejectDuplicatePayeeName(trimmedName, excluding: nil, db: db)

            var messages = [
                try builder.makeMessage(
                    dataset: "payees",
                    row: payeeID,
                    column: "name",
                    value: .string(trimmedName)
                )
            ]
            if columns.contains("tombstone") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "payees",
                        row: payeeID,
                        column: "tombstone",
                        value: .bool(false)
                    )
                )
            }
            if let mapping = try usablePayeeMappingColumns(db: db) {
                messages.append(
                    try builder.makeMessage(
                        dataset: "payee_mapping",
                        row: payeeID,
                        column: mapping.target,
                        value: .string(payeeID)
                    )
                )
            }
            return messages
        }
    }

    func renamePayeeMessages(
        payeeID: String,
        name: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedName = try validatedPayeeName(name)
        return try queue.read { db in
            let payee = try requiredRegularPayee(payeeID, db: db)
            guard payee.name != trimmedName else {
                return []
            }
            try rejectDuplicatePayeeName(trimmedName, excluding: payeeID, db: db)
            return [
                try builder.makeMessage(
                    dataset: "payees",
                    row: payeeID,
                    column: "name",
                    value: .string(trimmedName)
                )
            ]
        }
    }

    func mergePayeeMessages(
        sourcePayeeIDs: Set<String>,
        targetPayeeID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            guard !sourcePayeeIDs.isEmpty, !sourcePayeeIDs.contains(targetPayeeID) else {
                throw LocalFirstError.invalidLocalWrite("choose at least one different payee to merge")
            }
            _ = try requiredColumns(
                table: "payees",
                required: ["name", "tombstone"],
                db: db
            )
            _ = try requiredRegularPayee(targetPayeeID, db: db)
            for sourceID in sourcePayeeIDs {
                _ = try requiredRegularPayee(sourceID, db: db)
            }
            guard let mapping = try usablePayeeMappingColumns(db: db) else {
                throw LocalFirstError.invalidLocalWrite("this budget does not support payee merging")
            }

            let placeholders = Array(repeating: "?", count: sourcePayeeIDs.count).joined(separator: ",")
            let mappedRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(quotedIdentifier(mapping.id)) AS id
                    FROM payee_mapping
                    WHERE \(quotedIdentifier(mapping.target)) IN (\(placeholders))
                    """,
                arguments: StatementArguments(Array(sourcePayeeIDs))
            )
            var mappingIDs = Set(mappedRows.compactMap { $0["id"] as String? })
            mappingIDs.formUnion(sourcePayeeIDs)

            var messages: [ActualSyncDecodedMessage] = []
            for mappingID in mappingIDs.sorted() {
                messages.append(
                    try builder.makeMessage(
                        dataset: "payee_mapping",
                        row: mappingID,
                        column: mapping.target,
                        value: .string(targetPayeeID)
                    )
                )
            }
            for sourceID in sourcePayeeIDs.sorted() {
                messages.append(
                    try builder.makeMessage(
                        dataset: "payees",
                        row: sourceID,
                        column: "tombstone",
                        value: .bool(true)
                    )
                )
            }
            return messages
        }
    }

    func deletePayeeMessages(
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            _ = try requiredColumns(
                table: "payees",
                required: ["name", "tombstone"],
                db: db
            )
            _ = try requiredRegularPayee(payeeID, db: db)

            let snapshot = try fetchPayeeManagementSnapshot(in: db)
            guard let payee = snapshot.payees.first(where: { $0.id == payeeID }), payee.canDelete else {
                throw LocalFirstError.invalidLocalWrite(
                    "only unused payees without rule references can be deleted"
                )
            }
            return [
                try builder.makeMessage(
                    dataset: "payees",
                    row: payeeID,
                    column: "tombstone",
                    value: .bool(true)
                )
            ]
        }
    }

    func updatePayeeManagementMessages(
        updates: [PayeeManagementUpdate],
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> (messages: [ActualSyncDecodedMessage], undo: [ActualSyncDecodedMessage]) {
        try queue.read { db in
            let columns = try columnSet(for: "payees", db: db)
            var messages: [ActualSyncDecodedMessage] = []
            var undo: [ActualSyncDecodedMessage] = []

            for update in updates {
                _ = try requiredRegularPayee(update.payeeID, db: db)
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM payees WHERE id = ? AND \(predicateForLiveRows(columns: columns))",
                    arguments: [update.payeeID]
                ) else {
                    throw LocalFirstError.invalidLocalWrite("payee no longer exists")
                }
                if let favorite = update.favorite {
                    guard columns.contains("favorite") else {
                        throw LocalFirstError.invalidLocalWrite("this budget does not support favorite payees")
                    }
                    let oldValue = flexibleBool(row["favorite"])
                    if oldValue != favorite {
                        messages.append(try builder.makeMessage(
                            dataset: "payees", row: update.payeeID, column: "favorite", value: .bool(favorite)
                        ))
                        undo.append(try builder.makeMessage(
                            dataset: "payees", row: update.payeeID, column: "favorite", value: .bool(oldValue)
                        ))
                    }
                }
                if let learnCategories = update.learnCategories {
                    guard columns.contains("learn_categories") else {
                        throw LocalFirstError.invalidLocalWrite("this budget does not support category learning")
                    }
                    let oldValue = row["learn_categories"] == nil
                        ? true
                        : flexibleBool(row["learn_categories"])
                    if oldValue != learnCategories {
                        messages.append(try builder.makeMessage(
                            dataset: "payees", row: update.payeeID, column: "learn_categories", value: .bool(learnCategories)
                        ))
                        undo.append(try builder.makeMessage(
                            dataset: "payees", row: update.payeeID, column: "learn_categories", value: .bool(oldValue)
                        ))
                    }
                }
            }
            return (messages, undo)
        }
    }

    func setGlobalCategoryLearningMessages(
        enabled: Bool,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> (messages: [ActualSyncDecodedMessage], undo: [ActualSyncDecodedMessage]) {
        try queue.read { db in
            let columns = try requiredColumns(table: "preferences", required: ["value"], db: db)
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM preferences WHERE id = ? \(columns.contains("tombstone") ? "AND (tombstone = 0 OR tombstone IS NULL)" : "")",
                arguments: ["learn-categories"]
            )
            let oldValue = (row?["value"] as String?).map { $0 != "false" } ?? true
            guard oldValue != enabled else {
                return ([], [])
            }
            var messages = [try builder.makeMessage(
                dataset: "preferences",
                row: "learn-categories",
                column: "value",
                value: .string(enabled ? "true" : "false")
            )]
            if row == nil, columns.contains("tombstone") {
                messages.append(try builder.makeMessage(
                    dataset: "preferences", row: "learn-categories", column: "tombstone", value: .bool(false)
                ))
            }
            let undo = [try builder.makeMessage(
                dataset: "preferences",
                row: "learn-categories",
                column: "value",
                value: .string(oldValue ? "true" : "false")
            )]
            return (messages, undo)
        }
    }

    func payeeUndoMessagesForRename(
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            let payee = try requiredRegularPayee(payeeID, db: db)
            return [try builder.makeMessage(
                dataset: "payees", row: payeeID, column: "name", value: .string(payee.name)
            )]
        }
    }

    func payeeUndoMessagesForDelete(
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        [try builder.makeMessage(
            dataset: "payees", row: payeeID, column: "tombstone", value: .bool(false)
        )]
    }

    func payeeUndoMessagesForCreate(
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        [try builder.makeMessage(
            dataset: "payees", row: payeeID, column: "tombstone", value: .bool(true)
        )]
    }

    func payeeUndoMessagesForMerge(
        sourcePayeeIDs: Set<String>,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            guard let mapping = try usablePayeeMappingColumns(db: db) else {
                throw LocalFirstError.invalidLocalWrite("this budget does not support payee merging")
            }
            let placeholders = Array(repeating: "?", count: sourcePayeeIDs.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT \(quotedIdentifier(mapping.id)) AS id, \(quotedIdentifier(mapping.target)) AS target_id FROM payee_mapping WHERE \(quotedIdentifier(mapping.target)) IN (\(placeholders)) OR \(quotedIdentifier(mapping.id)) IN (\(placeholders))",
                arguments: StatementArguments(Array(sourcePayeeIDs) + Array(sourcePayeeIDs))
            )
            var previousTargets = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, String)? in
                guard let id = row["id"] as String?, let target = row["target_id"] as String? else { return nil }
                return (id, target)
            })
            for sourceID in sourcePayeeIDs where previousTargets[sourceID] == nil {
                previousTargets[sourceID] = sourceID
            }
            var messages = try previousTargets.sorted(by: { $0.key < $1.key }).map { id, target in
                try builder.makeMessage(
                    dataset: "payee_mapping", row: id, column: mapping.target, value: .string(target)
                )
            }
            for sourceID in sourcePayeeIDs.sorted() {
                messages.append(try builder.makeMessage(
                    dataset: "payees", row: sourceID, column: "tombstone", value: .bool(false)
                ))
            }
            return messages
        }
    }

    private func fetchPayeeManagementSnapshot(in db: Database) throws -> PayeeManagementSnapshot {
        // This helper is used only while already inside a queue read transaction.
        let payeeColumns = try columnSet(for: "payees", db: db)
        let transferColumn = payeeColumns.contains("transfer_acct") ? "transfer_acct" : nil
        let favoriteColumn = payeeColumns.contains("favorite") ? "favorite" : nil
        let learnCategoriesColumn = payeeColumns.contains("learn_categories") ? "learn_categories" : nil
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name,
                       \(transferColumn.map { quotedIdentifier($0) } ?? "NULL") AS transfer_acct,
                       \(favoriteColumn.map { quotedIdentifier($0) } ?? "0") AS favorite,
                       \(learnCategoriesColumn.map { quotedIdentifier($0) } ?? "1") AS learn_categories
                FROM payees
                WHERE \(predicateForLiveRows(columns: payeeColumns))
                """
        )
        let accountNames = try fetchPayeeAccountNames(db: db)
        let usageCounts = try fetchPayeeTransactionCounts(db: db)
        let ruleReferences = try fetchPayeeRuleReferences(
            payeeIDs: Set(rows.compactMap { $0["id"] as String? }),
            db: db
        )
        let canTombstone = payeeColumns.contains("tombstone")
        let payees = rows.compactMap { row -> ManagedPayee? in
            guard let id = row["id"] as String?, !id.isEmpty else { return nil }
            let transfer = row["transfer_acct"] as String?
            let transactionCount = usageCounts[id] ?? 0
            let ruleCount = ruleReferences.counts[id] ?? 0
            let payee = ManagedPayee(
                id: id,
                name: row["name"] ?? "",
                transferAccountID: transfer,
                transferAccountName: transfer.flatMap { accountNames[$0] },
                transactionCount: transactionCount,
                ruleReferenceCount: ruleCount,
                canDelete: transfer == nil && transactionCount == 0 && ruleCount == 0
                    && !ruleReferences.hasUnreadableRules && canTombstone,
                favorite: flexibleBool(row["favorite"]),
                learnCategories: row["learn_categories"] == nil
                    ? true
                    : flexibleBool(row["learn_categories"])
            )
            guard !payee.isTransfer || !payee.displayName.isEmpty else {
                return nil
            }
            return payee
        }
        .sorted {
            if $0.isTransfer != $1.isTransfer {
                return !$0.isTransfer
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let globalLearningEnabled = try fetchGlobalCategoryLearningEnabled(db: db)
        return PayeeManagementSnapshot(
            payees: payees,
            supportsCreate: true,
            supportsRename: true,
            supportsMerge: (try usablePayeeMappingColumns(db: db)) != nil && canTombstone,
            supportsDelete: canTombstone,
            hasUnreadableRuleReferences: ruleReferences.hasUnreadableRules,
            supportsFavorite: favoriteColumn != nil,
            supportsCategoryLearning: learnCategoriesColumn != nil && globalLearningEnabled != nil,
            globalCategoryLearningEnabled: globalLearningEnabled ?? true
        )
    }

    private func fetchGlobalCategoryLearningEnabled(db: Database) throws -> Bool? {
        guard try tableExists("preferences", db: db) else {
            return nil
        }
        let columns = try columnSet(for: "preferences", db: db)
        guard columns.contains("id"), columns.contains("value") else {
            return nil
        }
        let value = try String.fetchOne(
            db,
            sql: "SELECT value FROM preferences WHERE id = ? \(columns.contains("tombstone") ? "AND (tombstone = 0 OR tombstone IS NULL)" : "") LIMIT 1",
            arguments: ["learn-categories"]
        )
        return value.map { $0 != "false" } ?? true
    }

    private func validatedPayeeName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("payee name cannot be empty")
        }
        return trimmed
    }

    private func rejectDuplicatePayeeName(
        _ name: String,
        excluding payeeID: String?,
        db: Database
    ) throws {
        let columns = try columnSet(for: "payees", db: db)
        var arguments: StatementArguments = [name]
        var exclusion = ""
        if let payeeID {
            exclusion = " AND id <> ?"
            arguments += [payeeID]
        }
        let regularPredicate = columns.contains("transfer_acct")
            ? "transfer_acct IS NULL"
            : "1"
        let duplicate = try String.fetchOne(
            db,
            sql: """
                SELECT id FROM payees
                WHERE \(predicateForLiveRows(columns: columns))
                  AND \(regularPredicate)
                  AND name = ? COLLATE NOCASE
                  \(exclusion)
                LIMIT 1
                """,
            arguments: arguments
        )
        guard duplicate == nil else {
            throw LocalFirstError.invalidLocalWrite(
                "a payee with that name already exists; merge the duplicates instead"
            )
        }
    }

    private func requiredRegularPayee(
        _ payeeID: String,
        db: Database
    ) throws -> (name: String, transferAccountID: String?) {
        let columns = try columnSet(for: "payees", db: db)
        let transfer = columns.contains("transfer_acct") ? "transfer_acct" : nil
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT name, \(transfer.map { quotedIdentifier($0) } ?? "NULL") AS transfer_acct
                FROM payees
                WHERE id = ? AND \(predicateForLiveRows(columns: columns))
                """,
            arguments: [payeeID]
        ) else {
            throw LocalFirstError.invalidLocalWrite("payee no longer exists")
        }
        let transferAccountID = row["transfer_acct"] as String?
        guard transferAccountID == nil else {
            throw LocalFirstError.invalidLocalWrite("transfer payees are managed with their accounts")
        }
        return (row["name"] ?? "", transferAccountID)
    }

    private func usablePayeeMappingColumns(db: Database) throws -> (id: String, target: String)? {
        guard try tableExists("payee_mapping", db: db) else {
            return nil
        }
        let columns = try columnSet(for: "payee_mapping", db: db)
        guard columns.contains("id") else {
            return nil
        }
        if columns.contains("targetId") {
            return ("id", "targetId")
        }
        if columns.contains("target_id") {
            return ("id", "target_id")
        }
        return nil
    }

    private func fetchPayeeAccountNames(db: Database) throws -> [String: String] {
        guard try tableExists("accounts", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "accounts", db: db)
        return Dictionary(
            uniqueKeysWithValues: try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name FROM accounts
                    WHERE \(predicateForLiveRows(columns: columns))
                    """
            ).compactMap { row in
                guard let id = row["id"] as String? else { return nil }
                return (id, row["name"] as String? ?? "")
            }
        )
    }

    private func fetchPayeeTransactionCounts(db: Database) throws -> [String: Int] {
        guard try tableExists("transactions", db: db) else {
            return [:]
        }
        let transactionColumns = try columnSet(for: "transactions", db: db)
        guard let payeeColumn = ["description", "payee"].first(where: transactionColumns.contains) else {
            return [:]
        }
        let liveTransactions = predicateForLiveRows(columns: transactionColumns)
        let liveAliasedTransactions = transactionColumns.contains("tombstone")
            ? "(t.tombstone = 0 OR t.tombstone IS NULL)"
            : "1"

        if let mapping = try usablePayeeMappingColumns(db: db) {
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT COALESCE(pm.\(quotedIdentifier(mapping.target)), t.\(quotedIdentifier(payeeColumn))) AS payee_id,
                           COUNT(*) AS usage_count
                    FROM transactions t
                    LEFT JOIN payee_mapping pm ON pm.\(quotedIdentifier(mapping.id)) = t.\(quotedIdentifier(payeeColumn))
                    WHERE \(liveAliasedTransactions)
                      AND t.\(quotedIdentifier(payeeColumn)) IS NOT NULL
                    GROUP BY COALESCE(pm.\(quotedIdentifier(mapping.target)), t.\(quotedIdentifier(payeeColumn)))
                    """
            )
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let id = row["payee_id"] as String? else { return nil }
                return (id, row["usage_count"] as Int? ?? 0)
            })
        }

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(quotedIdentifier(payeeColumn)) AS payee_id, COUNT(*) AS usage_count
                FROM transactions
                WHERE \(liveTransactions)
                  AND \(quotedIdentifier(payeeColumn)) IS NOT NULL
                GROUP BY \(quotedIdentifier(payeeColumn))
                """
        )
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let id = row["payee_id"] as String? else { return nil }
            return (id, row["usage_count"] as Int? ?? 0)
        })
    }

    private func fetchPayeeRuleReferences(
        payeeIDs: Set<String>,
        db: Database
    ) throws -> (counts: [String: Int], hasUnreadableRules: Bool) {
        guard try tableExists("rules", db: db) else {
            return ([:], false)
        }
        let columns = try columnSet(for: "rules", db: db)
        let jsonColumns = ["conditions", "actions"].filter(columns.contains)
        guard !jsonColumns.isEmpty else {
            return ([:], false)
        }
        let selectedColumns = (["id"].filter(columns.contains) + jsonColumns)
            .map(quotedIdentifier)
            .joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT \(selectedColumns) FROM rules WHERE \(predicateForLiveRows(columns: columns))"
        )
        let completedScheduleRules = try fetchRuleScheduleIndex(db: db).completedRuleIDs

        var mappedPayeeIDs = Dictionary(uniqueKeysWithValues: payeeIDs.map { ($0, $0) })
        if let mapping = try usablePayeeMappingColumns(db: db) {
            let mappingRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(quotedIdentifier(mapping.id)) AS id,
                           \(quotedIdentifier(mapping.target)) AS target_id
                    FROM payee_mapping
                    """
            )
            for mappingRow in mappingRows {
                guard let id = mappingRow["id"] as String?,
                      let target = mappingRow["target_id"] as String?,
                      payeeIDs.contains(target) else {
                    continue
                }
                mappedPayeeIDs[id] = target
            }
        }

        var counts: [String: Int] = [:]
        var hasUnreadableRules = false
        for row in rows {
            if let ruleID = row["id"] as String?, completedScheduleRules.contains(ruleID) {
                continue
            }
            var referencedByRule = Set<String>()
            for column in jsonColumns {
                guard let json = row[column] as String?, !json.isEmpty else {
                    continue
                }
                guard let data = json.data(using: .utf8),
                      let value = try? JSONSerialization.jsonObject(with: data) else {
                    hasUnreadableRules = true
                    continue
                }
                collectPayeeReferences(
                    in: value,
                    mappedPayeeIDs: mappedPayeeIDs,
                    into: &referencedByRule
                )
            }
            for payeeID in referencedByRule {
                counts[payeeID, default: 0] += 1
            }
        }
        return (counts, hasUnreadableRules)
    }

    private func collectPayeeReferences(
        in value: Any,
        mappedPayeeIDs: [String: String],
        into result: inout Set<String>
    ) {
        if let object = value as? [String: Any] {
            let field = (object["field"] as? String)?.lowercased()
            if field == "description" || field == "payee" {
                collectMatchingPayeeIDs(
                    in: object["value"],
                    mappedPayeeIDs: mappedPayeeIDs,
                    into: &result
                )
            }
            for nested in object.values {
                collectPayeeReferences(
                    in: nested,
                    mappedPayeeIDs: mappedPayeeIDs,
                    into: &result
                )
            }
        } else if let array = value as? [Any] {
            for nested in array {
                collectPayeeReferences(
                    in: nested,
                    mappedPayeeIDs: mappedPayeeIDs,
                    into: &result
                )
            }
        }
    }

    private func collectMatchingPayeeIDs(
        in value: Any?,
        mappedPayeeIDs: [String: String],
        into result: inout Set<String>
    ) {
        if let string = value as? String, let target = mappedPayeeIDs[string] {
            result.insert(target)
        } else if let array = value as? [Any] {
            for nested in array {
                collectMatchingPayeeIDs(
                    in: nested,
                    mappedPayeeIDs: mappedPayeeIDs,
                    into: &result
                )
            }
        } else if let object = value as? [String: Any] {
            for nested in object.values {
                collectMatchingPayeeIDs(
                    in: nested,
                    mappedPayeeIDs: mappedPayeeIDs,
                    into: &result
                )
            }
        }
    }
}
