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
        let balances = try accountBalances(in: database)
        let userNoteIDs = try EntityNoteSQL.fetchUserNoteIDs(
            for: Set(accounts.map { "account-\($0.id)" }),
            in: database
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

    static func accountBalances(in database: isolated BudgetDatabase) throws -> [String: Int] {
        try database.queue.read { db in try accountBalances(accountID: nil, in: database, db: db) }
    }

    /// The live inline balance of one account (future-dated rows included), or
    /// nil when the transactions table is missing.
    static func accountBalance(accountID: String, in database: isolated BudgetDatabase, db: Database) throws -> Int? {
        guard try database.tableExists("transactions", db: db) else { return nil }
        return try accountBalances(accountID: accountID, in: database, db: db)[accountID] ?? 0
    }

    /// Per-account balance of live inline rows; `accountID` limits it to one account.
    /// Split children are summed, as in Actual's account header and `account-balance`.
    /// Actual's sidebar row sums the parent instead, which differs only when a split's
    /// parts don't add up to its parent; the Accounts tab keeps matching the header.
    private static func accountBalances(accountID: String?, in database: isolated BudgetDatabase, db: Database) throws -> [String: Int] {
        guard try database.tableExists("transactions", db: db) else {
            return [:]
        }

        let columns = try database.columnSet(for: "transactions", db: db)
        let split = TransactionSplitQueryExpressions(columns: columns)
        let accountFilter = accountID == nil ? "" : "AND \(split.qualifiedAccount) = ?"
        let sql = """
            SELECT \(split.qualifiedAccount) AS account_id, SUM(\(split.qualifiedAmount)) AS balance
            FROM transactions t
            \(split.parentJoin())
            WHERE \(split.liveInlinePredicate())
              \(accountFilter)
            GROUP BY \(split.qualifiedAccount)
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: accountID.map { [$0] } ?? [])
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let accountID = row["account_id"] as String? else {
                return nil
            }
            return (accountID, row["balance"] ?? 0)
        })
    }

    static func accountIsOffBudget(_ accountID: String, in database: isolated BudgetDatabase) throws -> Bool {
        try database.queue.read { db in
            try accountOffBudget(accountID, in: database, db: db)
        }
    }

    static func accountOffBudget(_ accountID: String, in database: isolated BudgetDatabase, db: Database) throws -> Bool {
        guard try database.tableExists("accounts", db: db) else {
            return false
        }
        let columns = try database.columnSet(for: "accounts", db: db)
        let offbudgetColumn = database.column("offbudget", fallback: "0", columns: columns)
        guard offbudgetColumn != "0" else {
            return false
        }
        let value = try Int.fetchOne(
            db,
            sql: "SELECT \(offbudgetColumn) FROM accounts WHERE id = ?",
            arguments: [accountID]
        )
        return (value ?? 0) != 0
    }
}
