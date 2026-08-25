import Foundation
import GRDB

extension BudgetDatabase {
    static let accountGroupsMigrationID: Int64 = 1_787_013_118_115
    static let accountGroupSortIncrement: Double = 16_384

    func accountGroupManagementEnabled() throws -> Bool {
        try queue.read { db in
            try Self.accountGroupManagementEnabled(db: db)
        }
    }

    func createAccountGroupMessages(
        groupID: String,
        name: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = try Self.validatedAccountGroupName(name)
        guard !trimmedID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account group")
        }

        return try queue.read { db in
            try requireAccountGroupManagementEnabled(db: db)
            let columns = try requiredColumns(
                table: "account_groups",
                required: ["name"],
                db: db
            )
            if try rowExists(table: "account_groups", rowID: trimmedID, db: db) {
                throw LocalFirstError.invalidLocalWrite("account group already exists")
            }
            try rejectDuplicateAccountGroupName(trimmedName, excluding: nil, db: db)

            var messages = [
                try builder.makeMessage(
                    dataset: "account_groups",
                    row: trimmedID,
                    column: "name",
                    value: .string(trimmedName)
                )
            ]
            if columns.contains("tombstone") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "account_groups",
                        row: trimmedID,
                        column: "tombstone",
                        value: .bool(false)
                    )
                )
            }
            if columns.contains("sort_order") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "account_groups",
                        row: trimmedID,
                        column: "sort_order",
                        value: .double(try nextAccountGroupSortOrder(db: db))
                    )
                )
            }
            return messages
        }
    }

    func renameAccountGroupMessages(
        groupID: String,
        name: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedName = try Self.validatedAccountGroupName(name)
        return try queue.read { db in
            try requireAccountGroupManagementEnabled(db: db)
            let group = try requiredLiveAccountGroup(groupID, db: db)
            guard group.name != trimmedName else {
                return []
            }
            try rejectDuplicateAccountGroupName(trimmedName, excluding: groupID, db: db)
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

    func deleteAccountGroupMessages(
        groupID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            try requireAccountGroupManagementEnabled(db: db)
            _ = try requiredLiveAccountGroup(groupID, db: db)
            let accountColumns = try columnSet(for: "accounts", db: db)
            guard accountColumns.contains("account_group_id") else {
                throw LocalFirstError.invalidLocalWrite("missing column accounts.account_group_id")
            }

            var messages: [ActualSyncDecodedMessage] = []
            let memberIDs = try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM accounts
                    WHERE account_group_id = ?
                      AND \(predicateForLiveRows(columns: accountColumns))
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

            let groupColumns = try columnSet(for: "account_groups", db: db)
            if groupColumns.contains("tombstone") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "account_groups",
                        row: groupID,
                        column: "tombstone",
                        value: .bool(true)
                    )
                )
            }
            return messages
        }
    }

    func moveAccountToGroupMessages(
        accountID: String,
        groupID: String?,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            try requireAccountGroupManagementEnabled(db: db)
            let accountColumns = try requiredColumns(
                table: "accounts",
                required: ["account_group_id"],
                db: db
            )
            guard try rowExists(table: "accounts", rowID: accountID, db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing account")
            }
            if let groupID {
                _ = try requiredLiveAccountGroup(groupID, db: db)
            }

            let current = try String.fetchOne(
                db,
                sql: """
                    SELECT account_group_id FROM accounts
                    WHERE id = ? AND \(predicateForLiveRows(columns: accountColumns))
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

    func moveAccountGroupMessages(
        groupID: String,
        beforeGroupID: String?,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            try requireAccountGroupManagementEnabled(db: db)
            _ = try requiredLiveAccountGroup(groupID, db: db)
            if let beforeGroupID {
                _ = try requiredLiveAccountGroup(beforeGroupID, db: db)
            }
            let groups = try fetchLiveAccountGroupSortRows(db: db)
            let result = AccountGroupSort.shove(items: groups, targetID: beforeGroupID)
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

    private func requireAccountGroupManagementEnabled(db: Database) throws {
        guard try Self.accountGroupManagementEnabled(db: db) else {
            throw LocalFirstError.invalidLocalWrite("account groups are not available on this budget")
        }
    }

    private static func accountGroupManagementEnabled(db: Database) throws -> Bool {
        // The file the sync server stores is the last uploaded snapshot, not
        // the nightly process's migrated copy. `__migrations__` therefore lags
        // the server software. After Phase 1 backfill, local `account_groups`
        // is the writable schema.
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM sqlite_master
                    WHERE type = 'table' AND name = 'account_groups'
                )
                """
        ) ?? false
    }

    private static func validatedAccountGroupName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("account group name cannot be empty")
        }
        return trimmed
    }

    private func rejectDuplicateAccountGroupName(
        _ name: String,
        excluding groupID: String?,
        db: Database
    ) throws {
        let columns = try columnSet(for: "account_groups", db: db)
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
                WHERE \(predicateForLiveRows(columns: columns))
                  AND name = ? COLLATE NOCASE
                  \(exclusion)
                LIMIT 1
                """,
            arguments: arguments
        )
        if let existingName {
            throw LocalFirstError.invalidLocalWrite(
                "An '\(existingName)' account group already exists."
            )
        }
    }

    private func requiredLiveAccountGroup(
        _ groupID: String,
        db: Database
    ) throws -> (id: String, name: String) {
        let columns = try requiredColumns(
            table: "account_groups",
            required: ["name"],
            db: db
        )
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, name FROM account_groups
                WHERE id = ? AND \(predicateForLiveRows(columns: columns))
                LIMIT 1
                """,
            arguments: [groupID]
        ) else {
            throw LocalFirstError.invalidLocalWrite("account group no longer exists")
        }
        return (row["id"] ?? groupID, row["name"] ?? "")
    }

    private func nextAccountGroupSortOrder(db: Database) throws -> Double {
        let columns = try columnSet(for: "account_groups", db: db)
        guard columns.contains("sort_order") else {
            return Self.accountGroupSortIncrement
        }
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT MAX(sort_order) AS sort_order FROM account_groups
                WHERE \(predicateForLiveRows(columns: columns))
                """
        )
        return flexibleDouble(row?["sort_order"]) + Self.accountGroupSortIncrement
    }

    private func fetchLiveAccountGroupSortRows(
        db: Database
    ) throws -> [AccountGroupSort.Item] {
        let columns = try requiredColumns(
            table: "account_groups",
            required: ["id"],
            db: db
        )
        let sortOrder = column("sort_order", fallback: "0", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, \(sortOrder) AS sort_order
                FROM account_groups
                WHERE \(predicateForLiveRows(columns: columns))
                ORDER BY sort_order, id
                """
        )
        return rows.compactMap { row in
            guard let id = row["id"] as String?, !id.isEmpty else {
                return nil
            }
            return AccountGroupSort.Item(id: id, sortOrder: flexibleDouble(row["sort_order"]))
        }
    }
}

enum AccountGroupSort {
    struct Item: Equatable {
        var id: String
        var sortOrder: Double
    }

    struct Result: Equatable {
        var sortOrder: Double
        var updates: [Item]
    }

    static func shove(items: [Item], targetID: String?) -> Result {
        let increment = BudgetDatabase.accountGroupSortIncrement
        guard let targetID,
              let targetIndex = items.firstIndex(where: { $0.id == targetID }) else {
            let order: Double
            if let last = items.last {
                order = last.sortOrder + increment
            } else {
                order = increment
            }
            return Result(sortOrder: order, updates: [])
        }

        let target = items[targetIndex]
        let before = targetIndex > 0 ? items[targetIndex - 1] : nil
        var updates: [Item] = []
        if target.sortOrder - (before?.sortOrder ?? 0) <= 2 {
            var next = targetIndex
            var order = items[next].sortOrder.rounded(.down) + increment
            while next < items.count {
                if order <= items[next].sortOrder {
                    break
                }
                updates.append(Item(id: items[next].id, sortOrder: order))
                next += 1
                order += increment
            }
        }

        return Result(
            sortOrder: midpoint(items: items, targetIndex: targetIndex, increment: increment),
            updates: updates
        )
    }

    private static func midpoint(
        items: [Item],
        targetIndex: Int,
        increment: Double
    ) -> Double {
        let below = targetIndex > 0 ? items[targetIndex - 1] : nil
        let above = items[targetIndex]
        if below == nil {
            return above.sortOrder / 2
        }
        if targetIndex >= items.count {
            return (below?.sortOrder ?? 0) + increment
        }
        if let below {
            return (below.sortOrder + above.sortOrder) / 2
        }
        return above.sortOrder / 2
    }
}
