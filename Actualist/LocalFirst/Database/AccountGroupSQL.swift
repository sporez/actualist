import Foundation
import GRDB

enum AccountGroupSQL {
    static let accountGroupsMigrationID: Int64 = 1_787_013_118_115

    static func fetchAccountGroups(in database: isolated BudgetDatabase) throws -> [ActualAccountGroup] {
        try database.queue.read { db in
            guard try database.tableExists("account_groups", db: db) else {
                return []
            }

            let columns = try database.columnSet(for: "account_groups", db: db)
            let name = database.column("name", fallback: "''", columns: columns)
            let sortOrder = database.column("sort_order", fallback: "0", columns: columns)
            let order = columns.contains("sort_order") ? "sort_order, id" : "id"
            let sql = """
                SELECT id, \(name) AS name, \(sortOrder) AS sort_order
                FROM account_groups
                WHERE \(database.predicateForLiveRows(columns: columns))
                ORDER BY \(order)
                """
            return try Row.fetchAll(db, sql: sql).compactMap { row in
                let id = row["id"] as String? ?? ""
                guard !id.isEmpty else {
                    return nil
                }
                return ActualAccountGroup(
                    id: id,
                    name: row["name"] ?? "",
                    sortOrder: SQLiteValueCoercion.lenientDouble(row["sort_order"])
                )
            }
        }
    }

    static func createAccountGroupMessages(
        groupID: String,
        name: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = try EntityName.validatedName(name, label: "account group")
        guard !trimmedID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account group")
        }

        return try database.queue.read { db in
            let columns = try database.requiredColumns(
                table: "account_groups",
                required: ["name"],
                db: db
            )
            if try database.rowExists(table: "account_groups", rowID: trimmedID, db: db) {
                throw LocalFirstError.invalidLocalWrite("account group already exists")
            }
            try rejectDuplicateAccountGroupName(trimmedName, excluding: nil, in: database, db: db)

            var messages = [
                try builder.makeMessage(
                    dataset: "account_groups",
                    row: trimmedID,
                    column: "name",
                    value: .string(trimmedName)
                )
            ]
            if columns.contains("sort_order") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "account_groups",
                        row: trimmedID,
                        column: "sort_order",
                        value: .double(try nextAccountGroupSortOrder(in: database, db: db))
                    )
                )
            }
            return messages
        }
    }

    static func renameAccountGroupMessages(
        groupID: String,
        name: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let groupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = try EntityName.validatedName(name, label: "account group")
        return try database.queue.read { db in
            let group = try requiredLiveAccountGroup(groupID, in: database, db: db)
            guard group.name != trimmedName else {
                return []
            }
            try rejectDuplicateAccountGroupName(trimmedName, excluding: groupID, in: database, db: db)
            return [
                try builder.makeMessage(
                    dataset: "account_groups",
                    row: groupID,
                    column: "name",
                    value: .string(trimmedName)
                )
            ]
        }
    }

    static func deleteAccountGroupMessages(
        groupID: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let groupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        return try database.queue.read { db in
            _ = try requiredLiveAccountGroup(groupID, in: database, db: db)
            let accountColumns = try database.columnSet(for: "accounts", db: db)
            guard accountColumns.contains("account_group_id") else {
                throw LocalFirstError.invalidLocalWrite("missing column accounts.account_group_id")
            }
            // Without the tombstone the group would stay live while its members
            // were already ungrouped, so a missing column is a failure.
            _ = try database.requiredColumns(table: "account_groups", required: ["tombstone"], db: db)

            var messages: [ActualSyncDecodedMessage] = []
            let memberIDs = try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM accounts
                    WHERE account_group_id = ?
                      AND \(database.predicateForLiveRows(columns: accountColumns))
                    ORDER BY id
                    """,
                arguments: [groupID]
            )
            for memberID in memberIDs {
                messages.append(
                    try builder.makeMessage(
                        dataset: "accounts",
                        row: memberID,
                        column: "account_group_id",
                        value: .null
                    )
                )
            }

            messages.append(
                try builder.tombstone(dataset: "account_groups", row: groupID)
            )
            return messages
        }
    }

    static func moveAccountToGroupMessages(
        accountID: String,
        groupID: String?,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        try database.queue.read { db in
            let accountColumns = try database.requiredColumns(
                table: "accounts",
                required: ["account_group_id"],
                db: db
            )
            guard try database.liveRowExists(table: "accounts", rowID: accountID, db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing account")
            }
            if let groupID {
                _ = try requiredLiveAccountGroup(groupID, in: database, db: db)
            }

            let current = try String.fetchOne(
                db,
                sql: """
                    SELECT account_group_id FROM accounts
                    WHERE id = ? AND \(database.predicateForLiveRows(columns: accountColumns))
                    LIMIT 1
                    """,
                arguments: [accountID]
            )
            let normalizedCurrent = current.flatMap { $0.isEmpty ? nil : $0 }
            guard normalizedCurrent != groupID else {
                return []
            }

            return [
                try builder.makeMessage(
                    dataset: "accounts",
                    row: accountID,
                    column: "account_group_id",
                    value: groupID.map(LocalFirstSyncValue.string) ?? .null
                )
            ]
        }
    }

    static func moveAccountGroupMessages(
        groupID: String,
        beforeGroupID: String?,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        try database.queue.read { db in
            _ = try requiredLiveAccountGroup(groupID, in: database, db: db)
            if let beforeGroupID {
                _ = try requiredLiveAccountGroup(beforeGroupID, in: database, db: db)
            }
            let groups = try fetchLiveAccountGroupSortRows(in: database, db: db)
            let result = ActualSortOrder.shove(items: groups, targetID: beforeGroupID)
            var messages: [ActualSyncDecodedMessage] = []
            for update in result.updates where update.id != groupID {
                messages.append(
                    try builder.makeMessage(
                        dataset: "account_groups",
                        row: update.id,
                        column: "sort_order",
                        value: .double(update.sortOrder)
                    )
                )
            }
            if groups.first(where: { $0.id == groupID })?.sortOrder != result.sortOrder {
                messages.append(
                    try builder.makeMessage(
                        dataset: "account_groups",
                        row: groupID,
                        column: "sort_order",
                        value: .double(result.sortOrder)
                    )
                )
            }
            return messages
        }
    }

    private static func rejectDuplicateAccountGroupName(
        _ name: String,
        excluding groupID: String?,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws {
        let columns = try database.columnSet(for: "account_groups", db: db)
        var arguments: StatementArguments = [name]
        var exclusion = ""
        if let groupID {
            exclusion = " AND id <> ?"
            arguments += [groupID]
        }
        let existingName = try String.fetchOne(
            db,
            sql: """
                SELECT name FROM account_groups
                WHERE \(database.predicateForLiveRows(columns: columns))
                  AND name = ? COLLATE NOCASE
                  \(exclusion)
                LIMIT 1
                """,
            arguments: arguments
        )
        if let existingName {
            throw LocalFirstError.refusedChange(
                "An account group named \(existingName) already exists."
            )
        }
    }

    private static func requiredLiveAccountGroup(
        _ groupID: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> (id: String, name: String) {
        let columns = try database.requiredColumns(
            table: "account_groups",
            required: ["name"],
            db: db
        )
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, name FROM account_groups
                WHERE id = ? AND \(database.predicateForLiveRows(columns: columns))
                LIMIT 1
                """,
            arguments: [groupID]
        ) else {
            throw LocalFirstError.invalidLocalWrite("account group no longer exists")
        }
        return (row["id"] ?? groupID, row["name"] ?? "")
    }

    private static func nextAccountGroupSortOrder(in database: isolated BudgetDatabase, db: Database) throws -> Double {
        let columns = try database.columnSet(for: "account_groups", db: db)
        guard columns.contains("sort_order") else {
            return ActualSortOrder.increment
        }
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT MAX(sort_order) AS sort_order FROM account_groups
                WHERE \(database.predicateForLiveRows(columns: columns))
                """
        )
        return SQLiteValueCoercion.lenientDouble(row?["sort_order"]) + ActualSortOrder.increment
    }

    private static func fetchLiveAccountGroupSortRows(
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSortOrder.Item] {
        let columns = try database.requiredColumns(
            table: "account_groups",
            required: ["id"],
            db: db
        )
        let sortOrder = database.column("sort_order", fallback: "0", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, \(sortOrder) AS sort_order
                FROM account_groups
                WHERE \(database.predicateForLiveRows(columns: columns))
                ORDER BY sort_order, id
                """
        )
        return rows.compactMap { row in
            guard let id = row["id"] as String?, !id.isEmpty else {
                return nil
            }
            return ActualSortOrder.Item(id: id, sortOrder: SQLiteValueCoercion.lenientDouble(row["sort_order"]))
        }
    }
}
