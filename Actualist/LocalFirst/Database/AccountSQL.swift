import Foundation
import GRDB

enum AccountSQL {
    static func fetchAccounts(in database: isolated BudgetDatabase) throws -> [ActualAccount] {
        try database.queue.read { db in
            guard try database.tableExists("accounts", db: db) else {
                return []
            }

            let columns = try database.columnSet(for: "accounts", db: db)
            let id = database.column("id", fallback: "''", columns: columns)
            let name = database.column("name", fallback: id, columns: columns)
            let offbudget = database.column("offbudget", fallback: "0", columns: columns)
            let closed = database.column("closed", fallback: "0", columns: columns)
            let bank = database.column("bank", fallback: "NULL", columns: columns)
            let accountSyncSource = database.column(
                "account_sync_source",
                fallback: database.column("bank_sync_source", fallback: "NULL", columns: columns),
                columns: columns
            )
            let bankSyncStatus = database.column("bank_sync_status", fallback: "NULL", columns: columns)
            let accountGroupID = database.column("account_group_id", fallback: "NULL", columns: columns)
            let tombstonePredicate = database.predicateForLiveRows(columns: columns)
            let order = columns.contains("sort_order") ? "sort_order, lower(name)" : "lower(name)"
            let sql = """
                SELECT \(id) AS id,
                       \(name) AS name,
                       \(offbudget) AS offbudget,
                       \(closed) AS closed,
                       \(bank) AS bank,
                       \(accountSyncSource) AS account_sync_source,
                       \(bankSyncStatus) AS bank_sync_status,
                       \(accountGroupID) AS account_group_id
                FROM accounts
                WHERE \(tombstonePredicate)
                ORDER BY \(order)
                """

            return try Row.fetchAll(db, sql: sql).map { row in
                let bankID = row["bank"] as String?
                let syncSource = row["account_sync_source"] as String?
                let groupID = (row["account_group_id"] as String?).flatMap { value in
                    value.isEmpty ? nil : value
                }
                return ActualAccount(
                    id: row["id"] ?? "",
                    name: row["name"] ?? "",
                    offbudget: SQLiteValueCoercion.lenientBool(row["offbudget"]),
                    closed: SQLiteValueCoercion.lenientBool(row["closed"]),
                    bankSyncLinked: bankID?.isEmpty == false || syncSource?.isEmpty == false,
                    bankSyncStatus: row["bank_sync_status"],
                    accountGroupId: groupID
                )
            }
        }
    }

    static func fetchAccountDisplays(in database: isolated BudgetDatabase) throws -> [AccountDisplay] {
        let accounts = try fetchAccounts(in: database)
        let balances = try database.accountBalances()
        let userNoteIDs = try database.fetchUserNoteIDs(
            for: Set(accounts.map { "account-\($0.id)" })
        )
        return accounts.map { account in
            AccountDisplay(
                account: account,
                balance: balances[account.id] ?? 0,
                hasUserNote: userNoteIDs.contains("account-\(account.id)")
            )
        }
    }

    static func createAccountMessages(
        accountID: String,
        name: String,
        offbudget: Bool,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccountID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }
        guard !trimmedName.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account name")
        }

        return try database.queue.read { db in
            let accountColumns = try database.requiredColumns(
                table: "accounts",
                required: ["name"],
                db: db
            )
            if try database.rowExists(table: "accounts", rowID: trimmedAccountID, db: db) {
                throw LocalFirstError.invalidLocalWrite("account already exists")
            }

            var messages: [ActualSyncDecodedMessage] = [
                try builder.makeMessage(
                    dataset: "accounts",
                    row: trimmedAccountID,
                    column: "name",
                    value: .string(trimmedName)
                )
            ]
            if accountColumns.contains("offbudget") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "accounts",
                        row: trimmedAccountID,
                        column: "offbudget",
                        value: .bool(offbudget)
                    )
                )
            }
            if accountColumns.contains("closed") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "accounts",
                        row: trimmedAccountID,
                        column: "closed",
                        value: .bool(false)
                    )
                )
            }
            if accountColumns.contains("tombstone") {
                messages.append(
                    try builder.revive(dataset: "accounts", row: trimmedAccountID)
                )
            }
            if accountColumns.contains("sort_order") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "accounts",
                        row: trimmedAccountID,
                        column: "sort_order",
                        value: .int(Int64(nextAccountSortOrder(offbudget: offbudget, in: database, db: db)))
                    )
                )
            }

            messages += try transferPayeeMessages(forAccountID: trimmedAccountID, builder: &builder, in: database, db: db)
            return messages
        }
    }

    private static func nextAccountSortOrder(offbudget: Bool, in database: isolated BudgetDatabase, db: Database) throws -> Int {
        let columns = try database.columnSet(for: "accounts", db: db)
        guard columns.contains("sort_order") else {
            return Int(ActualSortOrder.increment)
        }
        let offbudgetColumn = database.column("offbudget", fallback: "0", columns: columns)
        let maxSortOrder = try Int.fetchOne(
            db,
            sql: "SELECT MAX(sort_order) FROM accounts WHERE \(offbudgetColumn) = ?",
            arguments: [offbudget ? 1 : 0]
        )
        return (maxSortOrder ?? 0) + Int(ActualSortOrder.increment)
    }

    private static func transferPayeeMessages(
        forAccountID accountID: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        guard try database.tableExists("payees", db: db) else {
            return []
        }
        let payeeColumns = try database.requiredColumns(table: "payees", required: ["name"], db: db)
        let transferColumn = payeeColumns.contains("transfer_acct") ? "transfer_acct" : (
            payeeColumns.contains("transferAccount") ? "transferAccount" : nil
        )
        guard let transferColumn else {
            return []
        }

        let payeeID = UUID().uuidString
        var fields: [(String, LocalFirstSyncValue)] = [
            ("name", .string("")),
            (transferColumn, .string(accountID))
        ]
        if payeeColumns.contains("tombstone") {
            fields.append(("tombstone", .bool(false)))
        }
        if payeeColumns.contains("favorite") {
            fields.append(("favorite", .bool(false)))
        }
        if payeeColumns.contains("learn_categories") {
            fields.append(("learn_categories", .bool(false)))
        }
        if payeeColumns.contains("category") {
            fields.append(("category", .null))
        }

        var messages = try fields.map { field in
            try builder.makeMessage(dataset: "payees", row: payeeID, column: field.0, value: field.1)
        }

        if try database.tableExists("payee_mapping", db: db) {
            let mappingColumns = try database.requiredColumns(table: "payee_mapping", required: [], db: db)
            let targetColumn = try database.firstExistingColumn(
                PayeeMappingColumns.targetAliases,
                in: mappingColumns,
                table: "payee_mapping"
            )
            messages.append(
                try builder.makeMessage(
                    dataset: "payee_mapping",
                    row: payeeID,
                    column: targetColumn,
                    value: .string(payeeID)
                )
            )
        }
        return messages
    }
}
