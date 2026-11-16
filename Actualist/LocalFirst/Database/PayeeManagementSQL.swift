import Foundation
import GRDB

enum PayeeManagementSQL {
    static func fetchPayeeManagementSnapshot(in database: isolated BudgetDatabase) throws -> PayeeManagementSnapshot {
        try database.queue.read { db in
            guard try database.tableExists("payees", db: db) else {
                return .empty
            }
            let payeeColumns = try database.columnSet(for: "payees", db: db)
            guard payeeColumns.contains("id"), payeeColumns.contains("name") else {
                return .empty
            }
            return try fetchPayeeManagementSnapshot(in: database, db: db)
        }
    }

    static func createPayeeMessages(
        name: String,
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedName = try EntityName.validatedName(name, label: "payee")
        return try database.queue.read { db in
            _ = try database.requiredColumns(table: "payees", required: ["name"], db: db)
            try rejectPickerDuplicatePayeeName(name, in: database, db: db)

            var messages = [
                try builder.makeMessage(
                    dataset: "payees",
                    row: payeeID,
                    column: "name",
                    value: .string(trimmedName)
                )
            ]
            if let mapping = try usablePayeeMappingColumns(in: database, db: db) {
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

    static func renamePayeeMessages(
        payeeID: String,
        name: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedName = try EntityName.validatedName(name, label: "payee")
        return try database.queue.read { db in
            let payee = try requiredRegularPayee(payeeID, in: database, db: db)
            guard payee.name != trimmedName else {
                return []
            }
            try rejectDuplicatePayeeName(trimmedName, excluding: payeeID, in: database, db: db)
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

    /// Runs inside the caller's write transaction (`commitUserActionPlan`), so
    /// the mapping rows it retargets are the ones that exist at commit.
    static func mergePayeeMessages(
        sourcePayeeIDs: Set<String>,
        targetPayeeID: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        guard !sourcePayeeIDs.isEmpty, !sourcePayeeIDs.contains(targetPayeeID) else {
            throw LocalFirstError.refusedChange("Choose at least one other payee to merge.")
        }
        _ = try database.requiredColumns(
            table: "payees",
            required: ["name", "tombstone"],
            db: db
        )
        _ = try requiredRegularPayee(targetPayeeID, in: database, db: db)
        for sourceID in sourcePayeeIDs {
            _ = try requiredRegularPayee(sourceID, in: database, db: db)
        }
        guard let mapping = try usablePayeeMappingColumns(in: database, db: db) else {
            throw LocalFirstError.refusedChange("This budget does not support merging payees.")
        }

        let placeholders = Array(repeating: "?", count: sourcePayeeIDs.count).joined(separator: ",")
        let mappedRows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(database.quotedIdentifier(mapping.id)) AS id
                FROM payee_mapping
                WHERE \(database.quotedIdentifier(mapping.target)) IN (\(placeholders))
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
                try builder.tombstone(dataset: "payees", row: sourceID)
            )
        }
        return messages
    }

    static func deletePayeeMessages(
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        _ = try database.requiredColumns(
            table: "payees",
            required: ["name", "tombstone"],
            db: db
        )
        _ = try requiredRegularPayee(payeeID, in: database, db: db)

        return [
            try builder.tombstone(dataset: "payees", row: payeeID)
        ]
    }

    static func updatePayeeManagementMessages(
        updates: [PayeeManagementUpdate],
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> (messages: [ActualSyncDecodedMessage], undo: [ActualSyncDecodedMessage]) {
        try database.queue.read { db in
            let columns = try database.columnSet(for: "payees", db: db)
            var messages: [ActualSyncDecodedMessage] = []
            var undo: [ActualSyncDecodedMessage] = []

            for update in updates {
                _ = try requiredRegularPayee(update.payeeID, in: database, db: db)
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM payees WHERE id = ? AND \(database.predicateForLiveRows(columns: columns))",
                    arguments: [update.payeeID]
                ) else {
                    throw LocalFirstError.invalidLocalWrite("payee no longer exists")
                }
                if let favorite = update.favorite {
                    guard columns.contains("favorite") else {
                        throw LocalFirstError.refusedChange("This budget does not support favorite payees.")
                    }
                    let oldValue = SQLiteValueCoercion.lenientBool(row["favorite"])
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
                        throw LocalFirstError.refusedChange("This budget does not support category learning for payees.")
                    }
                    let oldValue = row["learn_categories"] == nil
                        ? true
                        : SQLiteValueCoercion.lenientBool(row["learn_categories"])
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

    static func setGlobalCategoryLearningMessages(
        enabled: Bool,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> (messages: [ActualSyncDecodedMessage], undo: [ActualSyncDecodedMessage]) {
        try database.queue.read { db in
            // The effective value treats anything but "false" as on, so a
            // stored non-canonical value is not rewritten.
            // An unavailable table falls through so `setMessages` throws.
            if try SyncedPreferences.availability(in: database, db: db) != .unavailable,
               try (SyncedPreferences.value(.learnCategories, in: database, db: db).map { $0 != "false" } ?? true) == enabled {
                return ([], [])
            }
            let result = try SyncedPreferences.setMessages(
                .learnCategories,
                to: enabled ? "true" : "false",
                builder: &builder,
                in: database,
                db: db
            )
            let oldValue = result.previousValue.map { $0 != "false" } ?? true
            let undo = [try SyncedPreferences.valueMessage(
                .learnCategories, oldValue ? "true" : "false", builder: &builder
            )]
            return (result.messages, undo)
        }
    }

    static func payeeUndoMessagesForRename(
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        try database.queue.read { db in
            let payee = try requiredRegularPayee(payeeID, in: database, db: db)
            return [try builder.makeMessage(
                dataset: "payees", row: payeeID, column: "name", value: .string(payee.name)
            )]
        }
    }

    static func payeeUndoMessagesForDelete(
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        [try builder.revive(dataset: "payees", row: payeeID)]
    }

    static func payeeUndoMessagesForCreate(
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        [try builder.tombstone(dataset: "payees", row: payeeID)]
    }

    static func payeeUndoMessagesForMerge(
        sourcePayeeIDs: Set<String>,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        guard let mapping = try usablePayeeMappingColumns(in: database, db: db) else {
            throw LocalFirstError.refusedChange("This budget does not support merging payees.")
        }
        let placeholders = Array(repeating: "?", count: sourcePayeeIDs.count).joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT \(database.quotedIdentifier(mapping.id)) AS id, \(database.quotedIdentifier(mapping.target)) AS target_id FROM payee_mapping WHERE \(database.quotedIdentifier(mapping.target)) IN (\(placeholders)) OR \(database.quotedIdentifier(mapping.id)) IN (\(placeholders))",
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
            messages.append(try builder.revive(dataset: "payees", row: sourceID))
        }
        return messages
    }

    private static func fetchPayeeManagementSnapshot(in database: isolated BudgetDatabase, db: Database) throws -> PayeeManagementSnapshot {
        // This helper is used only while already inside a queue read transaction.
        let payeeColumns = try database.columnSet(for: "payees", db: db)
        let transferColumn = payeeColumns.contains("transfer_acct") ? "transfer_acct" : nil
        let favoriteColumn = payeeColumns.contains("favorite") ? "favorite" : nil
        let learnCategoriesColumn = payeeColumns.contains("learn_categories") ? "learn_categories" : nil
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name,
                       \(transferColumn.map { database.quotedIdentifier($0) } ?? "NULL") AS transfer_acct,
                       \(favoriteColumn.map { database.quotedIdentifier($0) } ?? "0") AS favorite,
                       \(learnCategoriesColumn.map { database.quotedIdentifier($0) } ?? "1") AS learn_categories
                FROM payees
                WHERE \(database.predicateForLiveRows(columns: payeeColumns))
                """
        )
        let accountNames = try fetchPayeeAccountNames(in: database, db: db)
        let usageCounts = try fetchPayeeTransactionCounts(in: database, db: db)
        let livePayeeIDs = Set(rows.compactMap { $0["id"] as String? })
        let ruleReferences = try fetchPayeeRuleReferences(payeeIDs: livePayeeIDs, in: database, db: db)
        let conditionReferenced = try fetchConditionReferencedPayeeIDs(payeeIDs: livePayeeIDs, in: database, db: db)
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
                canDelete: transfer == nil && canTombstone,
                isUnused: transfer == nil && transactionCount == 0
                    && !conditionReferenced.contains(id),
                favorite: SQLiteValueCoercion.lenientBool(row["favorite"]),
                learnCategories: row["learn_categories"] == nil
                    ? true
                    : SQLiteValueCoercion.lenientBool(row["learn_categories"])
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
        let globalLearningEnabled = try fetchGlobalCategoryLearningEnabled(in: database, db: db)
        return PayeeManagementSnapshot(
            payees: payees,
            supportsCreate: true,
            supportsRename: true,
            supportsMerge: (try usablePayeeMappingColumns(in: database, db: db)) != nil && canTombstone,
            supportsDelete: canTombstone,
            hasUnreadableRuleReferences: ruleReferences.hasUnreadableRules,
            supportsFavorite: favoriteColumn != nil,
            supportsCategoryLearning: learnCategoriesColumn != nil && globalLearningEnabled != nil,
            globalCategoryLearningEnabled: globalLearningEnabled ?? true
        )
    }

    private static func fetchGlobalCategoryLearningEnabled(in database: isolated BudgetDatabase, db: Database) throws -> Bool? {
        guard try SyncedPreferences.availability(in: database, db: db) != .unavailable else {
            return nil
        }
        return try SyncedPreferences.value(.learnCategories, in: database, db: db).map { $0 != "false" } ?? true
    }

    /// Actual's payee picker offers "Create payee" only when no non-transfer payee's normalised
    /// name equals the normalised typed text, which is compared untrimmed.
    private static func rejectPickerDuplicatePayeeName(_ typedName: String, in database: isolated BudgetDatabase, db: Database) throws {
        let columns = try database.columnSet(for: "payees", db: db)
        let regularPredicate = columns.contains("transfer_acct") ? "transfer_acct IS NULL" : "1"
        let names = try String.fetchAll(
            db,
            sql: """
                SELECT name FROM payees
                WHERE \(database.predicateForLiveRows(columns: columns)) AND \(regularPredicate)
                """
        )
        let typed = typedName.actualNormalised
        guard !names.contains(where: { $0.actualNormalised == typed }) else {
            throw LocalFirstError.refusedChange(
                "A payee with that name already exists. Merge the duplicates instead."
            )
        }
    }

    /// Live payees whose mapping target is named by a live rule's top-level condition on
    /// `description` with a string value, as Actual's orphaned-payee query reads it.
    /// Completed-schedule rules count; actions and array values do not. Unreadable rule JSON
    /// counts as referencing every payee.
    private static func fetchConditionReferencedPayeeIDs(
        payeeIDs: Set<String>,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> Set<String> {
        guard try database.tableExists("rules", db: db) else { return [] }
        let columns = try database.columnSet(for: "rules", db: db)
        guard columns.contains("conditions") else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT conditions FROM rules WHERE \(database.predicateForLiveRows(columns: columns))"
        )
        var values = Set<String>()
        for row in rows {
            guard let json = row["conditions"] as String?, !json.isEmpty else { continue }
            guard let data = json.data(using: .utf8),
                  let conditions = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                return payeeIDs
            }
            for case let condition as [String: Any] in conditions {
                if condition["field"] as? String == "description",
                   let value = condition["value"] as? String {
                    values.insert(value)
                }
            }
        }
        guard !values.isEmpty else { return [] }
        var targets = Dictionary(uniqueKeysWithValues: payeeIDs.map { ($0, $0) })
        if let mapping = try usablePayeeMappingColumns(in: database, db: db) {
            let mappingRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(database.quotedIdentifier(mapping.id)) AS id,
                           \(database.quotedIdentifier(mapping.target)) AS target_id
                    FROM payee_mapping
                    """
            )
            for row in mappingRows {
                if let id = row["id"] as String?, payeeIDs.contains(id),
                   let target = row["target_id"] as String? {
                    targets[id] = target
                }
            }
        }
        return Set(payeeIDs.filter { values.contains(targets[$0] ?? $0) })
    }

    private static func rejectDuplicatePayeeName(
        _ name: String,
        excluding payeeID: String?,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws {
        let columns = try database.columnSet(for: "payees", db: db)
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
                WHERE \(database.predicateForLiveRows(columns: columns))
                  AND \(regularPredicate)
                  AND name = ? COLLATE NOCASE
                  \(exclusion)
                LIMIT 1
                """,
            arguments: arguments
        )
        guard duplicate == nil else {
            throw LocalFirstError.refusedChange(
                "A payee with that name already exists. Merge the duplicates instead."
            )
        }
    }

    private static func requiredRegularPayee(
        _ payeeID: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> (name: String, transferAccountID: String?) {
        let columns = try database.columnSet(for: "payees", db: db)
        let transfer = columns.contains("transfer_acct") ? "transfer_acct" : nil
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT name, \(transfer.map { database.quotedIdentifier($0) } ?? "NULL") AS transfer_acct
                FROM payees
                WHERE id = ? AND \(database.predicateForLiveRows(columns: columns))
                """,
            arguments: [payeeID]
        ) else {
            throw LocalFirstError.invalidLocalWrite("payee no longer exists")
        }
        let transferAccountID = row["transfer_acct"] as String?
        guard transferAccountID == nil else {
            throw LocalFirstError.refusedChange("Transfer payees are managed with their accounts.")
        }
        return (row["name"] ?? "", transferAccountID)
    }

    private static func usablePayeeMappingColumns(in database: isolated BudgetDatabase, db: Database) throws -> (id: String, target: String)? {
        guard try database.tableExists("payee_mapping", db: db) else {
            return nil
        }
        let columns = try database.columnSet(for: "payee_mapping", db: db)
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

    private static func fetchPayeeAccountNames(in database: isolated BudgetDatabase, db: Database) throws -> [String: String] {
        guard try database.tableExists("accounts", db: db) else {
            return [:]
        }
        let columns = try database.columnSet(for: "accounts", db: db)
        return Dictionary(
            uniqueKeysWithValues: try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name FROM accounts
                    WHERE \(database.predicateForLiveRows(columns: columns))
                    """
            ).compactMap { row in
                guard let id = row["id"] as String? else { return nil }
                return (id, row["name"] as String? ?? "")
            }
        )
    }

    private static func fetchPayeeTransactionCounts(in database: isolated BudgetDatabase, db: Database) throws -> [String: Int] {
        guard try database.tableExists("transactions", db: db) else {
            return [:]
        }
        let transactionColumns = try database.columnSet(for: "transactions", db: db)
        guard let payeeColumn = TransactionRowColumns.payee(in: transactionColumns) else {
            return [:]
        }
        let liveTransactions = database.predicateForLiveRows(columns: transactionColumns)
        let liveAliasedTransactions = transactionColumns.contains("tombstone")
            ? "(t.tombstone = 0 OR t.tombstone IS NULL)"
            : "1"

        if let mapping = try usablePayeeMappingColumns(in: database, db: db) {
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT COALESCE(pm.\(database.quotedIdentifier(mapping.target)), t.\(database.quotedIdentifier(payeeColumn))) AS payee_id,
                           COUNT(*) AS usage_count
                    FROM transactions t
                    LEFT JOIN payee_mapping pm ON pm.\(database.quotedIdentifier(mapping.id)) = t.\(database.quotedIdentifier(payeeColumn))
                    WHERE \(liveAliasedTransactions)
                      AND t.\(database.quotedIdentifier(payeeColumn)) IS NOT NULL
                    GROUP BY COALESCE(pm.\(database.quotedIdentifier(mapping.target)), t.\(database.quotedIdentifier(payeeColumn)))
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
                SELECT \(database.quotedIdentifier(payeeColumn)) AS payee_id, COUNT(*) AS usage_count
                FROM transactions
                WHERE \(liveTransactions)
                  AND \(database.quotedIdentifier(payeeColumn)) IS NOT NULL
                GROUP BY \(database.quotedIdentifier(payeeColumn))
                """
        )
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let id = row["payee_id"] as String? else { return nil }
            return (id, row["usage_count"] as Int? ?? 0)
        })
    }

    private static func fetchPayeeRuleReferences(
        payeeIDs: Set<String>,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> (counts: [String: Int], hasUnreadableRules: Bool) {
        guard try database.tableExists("rules", db: db) else {
            return ([:], false)
        }
        let columns = try database.columnSet(for: "rules", db: db)
        let jsonColumns = ["conditions", "actions"].filter(columns.contains)
        guard !jsonColumns.isEmpty else {
            return ([:], false)
        }
        let selectedColumns = (["id"].filter(columns.contains) + jsonColumns)
            .map(database.quotedIdentifier)
            .joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT \(selectedColumns) FROM rules WHERE \(database.predicateForLiveRows(columns: columns))"
        )
        let completedScheduleRules = try ScheduleSQL.fetchRuleScheduleIndex(in: database, db: db).completedRuleIDs

        var mappedPayeeIDs = Dictionary(uniqueKeysWithValues: payeeIDs.map { ($0, $0) })
        if let mapping = try usablePayeeMappingColumns(in: database, db: db) {
            let mappingRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(database.quotedIdentifier(mapping.id)) AS id,
                           \(database.quotedIdentifier(mapping.target)) AS target_id
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

    private static func collectPayeeReferences(
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

    private static func collectMatchingPayeeIDs(
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
