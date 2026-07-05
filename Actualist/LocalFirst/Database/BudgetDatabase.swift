import Foundation
import GRDB

private struct EnvelopeCategoryValue {
    var budgeted: Int = 0
    var spent: Int = 0
    var balance: Int = 0
    var carryover: Bool = false
}

private struct TransactionBudgetSource {
    let tableExists: Bool
    let table: String
    let account: String
    let category: String
    let amount: String
    let month: String
    let livePredicate: String
}

struct ActualSyncDecodedMessage: Equatable, Sendable {
    let timestamp: String
    let dataset: String
    let row: String
    let column: String
    let serializedValue: String
}

private enum ActualSyncSQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case string(String)
}

final class BudgetDatabase: @unchecked Sendable {
    let databaseURL: URL
    private let queue: DatabaseQueue

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        queue = try DatabaseQueue(path: databaseURL.path)
    }

    func fetchAccounts() throws -> [ActualAccount] {
        try queue.read { db in
            guard try tableExists("accounts", db: db) else {
                return []
            }

            let columns = try columnSet(for: "accounts", db: db)
            let id = column("id", fallback: "''", columns: columns)
            let name = column("name", fallback: id, columns: columns)
            let offbudget = column("offbudget", fallback: "0", columns: columns)
            let closed = column("closed", fallback: "0", columns: columns)
            let bankSync = column("bank_sync_source", fallback: "NULL", columns: columns)
            let tombstonePredicate = predicateForLiveRows(columns: columns)
            let order = columns.contains("sort_order") ? "sort_order, lower(name)" : "lower(name)"
            let sql = """
                SELECT \(id) AS id,
                       \(name) AS name,
                       \(offbudget) AS offbudget,
                       \(closed) AS closed,
                       \(bankSync) AS bank_sync_source
                FROM accounts
                WHERE \(tombstonePredicate)
                ORDER BY \(order)
                """

            return try Row.fetchAll(db, sql: sql).map { row in
                ActualAccount(
                    id: row["id"] ?? "",
                    name: row["name"] ?? "",
                    offbudget: flexibleBool(row["offbudget"]),
                    closed: flexibleBool(row["closed"]),
                    bankSyncLinked: (row["bank_sync_source"] as String?)?.isEmpty == false
                )
            }
        }
    }

    func fetchPayees() throws -> [ActualPayee] {
        try queue.read { db in
            guard try tableExists("payees", db: db) else {
                return []
            }

            let columns = try columnSet(for: "payees", db: db)
            let category = column("category", fallback: "NULL", columns: columns)
            let transferAccount = column("transfer_acct", fallback: "NULL", columns: columns)
            let sql = """
                SELECT id, name, \(category) AS category, \(transferAccount) AS transfer_acct
                FROM payees
                WHERE \(predicateForLiveRows(columns: columns))
                ORDER BY lower(name)
                """
            return try Row.fetchAll(db, sql: sql).map { row in
                ActualPayee(
                    id: row["id"],
                    name: row["name"] ?? "",
                    category: row["category"],
                    transferAccount: row["transfer_acct"]
                )
            }
        }
    }

    func fetchCategories() throws -> [ActualCategory] {
        try queue.read { db in
            guard try tableExists("categories", db: db) else {
                return []
            }

            let columns = try columnSet(for: "categories", db: db)
            let groupID = column("cat_group", fallback: column("group_id", fallback: "NULL", columns: columns), columns: columns)
            let hidden = column("hidden", fallback: "0", columns: columns)
            let isIncome = column("is_income", fallback: "0", columns: columns)
            let order = columns.contains("sort_order") ? "sort_order, lower(name)" : "lower(name)"
            let sql = """
                SELECT id, name, \(isIncome) AS is_income, \(hidden) AS hidden, \(groupID) AS group_id
                FROM categories
                WHERE \(predicateForLiveRows(columns: columns))
                ORDER BY \(order)
                """
            return try Row.fetchAll(db, sql: sql).map { row in
                ActualCategory(
                    id: row["id"],
                    name: row["name"] ?? "",
                    isIncome: flexibleBool(row["is_income"]),
                    hidden: flexibleBool(row["hidden"]),
                    groupID: row["group_id"]
                )
            }
        }
    }

    func fetchAvailableMonths() throws -> [String] {
        try queue.read { db in
            var months = Set<String>()
            if try tableExists("zero_budgets", db: db), try columnSet(for: "zero_budgets", db: db).contains("month") {
                let month = normalizedMonthExpression("month")
                let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT \(month) AS month FROM zero_budgets WHERE month IS NOT NULL")
                months.formUnion(rows.compactMap { flexibleString($0["month"]) })
            }
            if try tableExists("transactions", db: db), try columnSet(for: "transactions", db: db).contains("date") {
                let month = normalizedMonthExpression("date")
                let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT \(month) AS month FROM transactions WHERE date IS NOT NULL")
                months.formUnion(rows.compactMap { flexibleString($0["month"]) })
            }
            return months.sorted()
        }
    }

    func fetchAccountDisplays() throws -> [AccountDisplay] {
        let accounts = try fetchAccounts()
        let balances = try accountBalances()
        return accounts.map { account in
            AccountDisplay(account: account, balance: balances[account.id] ?? 0)
        }
    }

    func fetchBudgetMonth(month: String) throws -> BudgetMonth {
        try queue.read { db in
            let categoryValues = try envelopeCategoryValues(through: month, db: db)
            let groups = try fetchCategoryGroups(categoryValues: categoryValues, db: db)
            let expenseGroups = groups.filter { !$0.isIncome }
            let incomeGroups = groups.filter { $0.isIncome }
            let totalBudgeted = expenseGroups.reduce(0) { $0 + $1.budgeted }
            let totalSpent = expenseGroups.reduce(0) { $0 + $1.spent }
            let totalBalance = expenseGroups.reduce(0) { $0 + $1.balance }
            let totalIncome = incomeGroups.reduce(0) { $0 + $1.spent }
            // "To Budget" is the running amount of on-budget money not yet assigned to a
            // category. Uncategorized rows are intentionally ignored here: Actual leaves them
            // out of both category balances and To Budget until the user categorizes them.
            let onBudgetBalance = try onBudgetAccountBalance(through: month, db: db)
            let uncategorizedActivity = try uncategorizedOnBudgetActivity(through: month, db: db)
            let toBudget = (onBudgetBalance - uncategorizedActivity) - totalBalance

            return BudgetMonth(
                month: month,
                incomeAvailable: toBudget,
                lastMonthOverspent: 0,
                forNextMonth: 0,
                totalBudgeted: totalBudgeted,
                toBudget: toBudget,
                fromLastMonth: 0,
                totalIncome: totalIncome,
                totalSpent: totalSpent,
                totalBalance: totalBalance,
                categoryGroups: groups
            )
        }
    }

    /// Live transactions for a single account (when `accountID` is set) or across every
    /// account (spending feed). Parent rows carry their split children as `subtransactions`;
    /// tombstoned rows and children of tombstoned parents are excluded. Newest first.
    /// `query`, when set, filters on payee name / notes / amount.
    func fetchTransactions(accountID: String? = nil, matching query: String? = nil) throws -> [ActualTransaction] {
        try queue.read { db in
            guard try tableExists("transactions", db: db) else {
                return []
            }

            let columns = try columnSet(for: "transactions", db: db)
            // Alias-qualified column when present, or a bare SQL literal fallback when absent
            // (so a missing column becomes `NULL`/`0`, never an invalid `t.NULL`).
            func expr(_ names: [String], fallback: String) -> String {
                for name in names where columns.contains(name) {
                    return "t.\(name)"
                }
                return fallback
            }
            let account = expr(["acct", "account"], fallback: "NULL")
            let date = expr(["date"], fallback: "NULL")
            let amount = expr(["amount"], fallback: "0")
            // Actual stores the payee id in `description` (the `payee` alias only exists in views).
            let payee = expr(["payee", "description"], fallback: "NULL")
            let category = expr(["category"], fallback: "NULL")
            let notes = expr(["notes"], fallback: "NULL")
            let cleared = expr(["cleared"], fallback: "0")
            let importedPayee = expr(["imported_description", "imported_payee"], fallback: "NULL")
            let parentID = expr(["parent_id"], fallback: "NULL")
            let isParent = expr(["isParent", "is_parent"], fallback: "0")
            let normalizedDate = normalizedDateExpression(date)
            let hasCategoryMapping = try tableExists("category_mapping", db: db)
            let mappedCategory = hasCategoryMapping ? "COALESCE(cm.transferId, \(category))" : category
            let categoryMappingJoin = hasCategoryMapping ? "LEFT JOIN category_mapping cm ON cm.id = \(category)" : ""
            // Payees are resolved through payee_mapping (id -> targetId), like categories through
            // category_mapping. Without it, a remapped/merged payee id fails to resolve to a name.
            let hasPayeeMapping = try tableExists("payee_mapping", db: db)
            let mappedPayee = hasPayeeMapping ? "COALESCE(pm.targetId, \(payee))" : payee
            let payeeMappingJoin = hasPayeeMapping ? "LEFT JOIN payee_mapping pm ON pm.id = \(payee)" : ""
            let hasPayees = try tableExists("payees", db: db)
            let hasAccounts = try tableExists("accounts", db: db)
            let payeeColumns = hasPayees ? try columnSet(for: "payees", db: db) : []
            // Transfer payees have an empty name and a `transfer_acct`; their display name is the
            // linked account's name.
            let resolvesTransferNames = hasPayees && hasAccounts && payeeColumns.contains("transfer_acct")
            let payeeNameJoin: String
            let payeeNameSelect: String
            if hasPayees {
                if resolvesTransferNames {
                    payeeNameJoin = "LEFT JOIN payees py ON py.id = \(mappedPayee) LEFT JOIN accounts pax ON pax.id = py.transfer_acct"
                    payeeNameSelect = "COALESCE(NULLIF(py.name, ''), pax.name)"
                } else {
                    payeeNameJoin = "LEFT JOIN payees py ON py.id = \(mappedPayee)"
                    payeeNameSelect = "py.name"
                }
            } else {
                payeeNameJoin = ""
                payeeNameSelect = "NULL"
            }

            var conditions: [String] = [
                predicateForLiveRows(columns: columns, tableAlias: "t"),
                "(\(parentID) IS NULL OR p.tombstone = 0 OR p.tombstone IS NULL)"
            ]
            var arguments: [DatabaseValueConvertible] = []
            if let accountID {
                conditions.append("\(account) = ?")
                arguments.append(accountID)
            }
            if let query, !query.isEmpty {
                conditions.append("(\(payeeNameSelect) LIKE ? OR \(notes) LIKE ? OR CAST(\(amount) AS TEXT) LIKE ?)")
                let like = "%\(query)%"
                arguments.append(contentsOf: [like, like, like])
            }

            let sql = """
                SELECT t.id AS id,
                       \(account) AS account_id,
                       \(normalizedDate) AS date,
                       \(amount) AS amount,
                       \(mappedPayee) AS payee_id,
                       \(payeeNameSelect) AS payee_name,
                       \(importedPayee) AS imported_payee,
                       \(mappedCategory) AS category_id,
                       \(notes) AS notes,
                       \(cleared) AS cleared,
                       \(parentID) AS parent_id,
                       \(isParent) AS is_parent
                FROM transactions t
                \(categoryMappingJoin)
                \(payeeMappingJoin)
                \(payeeNameJoin)
                LEFT JOIN transactions p ON p.id = \(parentID)
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY \(date) DESC, t.id DESC
                """

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return assembleTransactions(from: rows)
        }
    }

    /// Groups flat rows into parent transactions with their split children attached.
    private func assembleTransactions(from rows: [Row]) -> [ActualTransaction] {
        var childrenByParent: [String: [ActualTransaction]] = [:]
        var parents: [ActualTransaction] = []

        for row in rows {
            let transaction = mapTransactionRow(row)
            if let parentID = transaction.parentID, !parentID.isEmpty {
                childrenByParent[parentID, default: []].append(transaction)
            } else {
                parents.append(transaction)
            }
        }

        return parents.map { parent in
            guard let id = parent.id, let children = childrenByParent[id], !children.isEmpty else {
                return parent
            }
            return parent.replacingSubtransactions(children)
        }
    }

    private func mapTransactionRow(_ row: Row) -> ActualTransaction {
        let parentID = row["parent_id"] as String?
        let payeeName = (row["payee_name"] as String?).flatMap { $0.isEmpty ? nil : $0 }
        let amount: Int? = row["amount"]
        return ActualTransaction(
            id: row["id"],
            account: row["account_id"] ?? "",
            date: row["date"] ?? "",
            amount: amount.map { actualAmountToMinorUnits($0) },
            payee: row["payee_id"],
            payeeName: payeeName,
            importedPayee: row["imported_payee"],
            category: row["category_id"],
            notes: row["notes"],
            cleared: flexibleBool(row["cleared"]) ? .bool(true) : .bool(false),
            isParent: flexibleBool(row["is_parent"]),
            isChild: (parentID?.isEmpty == false),
            parentID: parentID
        )
    }

    func latestSyncTimestamp() throws -> String {
        try queue.read { db in
            guard try tableExists("messages_crdt", db: db) else {
                return "1970-01-01T00:00:00.000Z-0000-0000000000000000"
            }
            let row = try Row.fetchOne(db, sql: "SELECT MAX(timestamp) AS timestamp FROM messages_crdt")
            return row?["timestamp"] as String? ?? "1970-01-01T00:00:00.000Z-0000-0000000000000000"
        }
    }

    func applyRemoteSyncMessages(_ messages: [ActualSyncDecodedMessage]) throws -> Int {
        guard !messages.isEmpty else {
            return 0
        }

        return try queue.write { db in
            guard try tableExists("messages_crdt", db: db) else {
                return 0
            }

            var appliedCount = 0
            let sortedMessages = messages.sorted { $0.timestamp < $1.timestamp }
            var insertedRows = Set<String>()

            for message in sortedMessages {
                guard try tableExists(message.dataset, db: db) else {
                    continue
                }

                if try hasSameOrNewerMessage(message, db: db) {
                    continue
                }

                let rowWasInserted = insertedRows.contains(message.dataset + message.row)
                let hasRow: Bool
                if rowWasInserted {
                    hasRow = true
                } else {
                    hasRow = try rowExists(table: message.dataset, rowID: message.row, db: db)
                }
                let value = try deserializeSyncValue(message.serializedValue)
                if message.dataset != "prefs" {
                    try apply(message: message, value: value, rowExists: hasRow, db: db)
                    insertedRows.insert(message.dataset + message.row)
                }
                try insertCRDTMessage(message, db: db)
                appliedCount += 1
            }

            return appliedCount
        }
    }

    func applyLocalSyncMessages(_ messages: [ActualSyncDecodedMessage]) throws -> Int {
        guard !messages.isEmpty else {
            return 0
        }

        return try queue.write { db in
            guard try tableExists("messages_crdt", db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing messages_crdt table")
            }

            var appliedCount = 0
            let sortedMessages = messages.sorted { $0.timestamp < $1.timestamp }
            var insertedRows = Set<String>()

            for message in sortedMessages {
                try validateLocalMessage(message, db: db)

                if try hasSameOrNewerMessage(message, db: db) {
                    continue
                }

                let rowWasInserted = insertedRows.contains(message.dataset + message.row)
                let hasRow: Bool
                if rowWasInserted {
                    hasRow = true
                } else {
                    hasRow = try rowExists(table: message.dataset, rowID: message.row, db: db)
                }

                let value = try deserializeSyncValue(message.serializedValue)
                try apply(message: message, value: value, rowExists: hasRow, db: db)
                insertedRows.insert(message.dataset + message.row)
                try insertCRDTMessage(message, db: db)
                appliedCount += 1
            }

            return appliedCount
        }
    }

    func resolveOrCreatePayeeMessages(
        selectedPayeeID: String?,
        payeeName: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> (payeeID: String, messages: [ActualSyncDecodedMessage]) {
        if let selectedPayeeID, !selectedPayeeID.isEmpty {
            return (selectedPayeeID, [])
        }

        let trimmedName = payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing payee name")
        }

        if let existing = try fetchPayees().first(where: {
            $0.transferAccount == nil && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }), let id = existing.id, !id.isEmpty {
            return (id, [])
        }

        let payeeID = UUID().uuidString
        var messages: [ActualSyncDecodedMessage] = []
        try queue.read { db in
            let payeeColumns = try requiredColumns(
                table: "payees",
                required: ["name"],
                db: db
            )
            messages.append(
                builder.makeMessage(
                    dataset: "payees",
                    row: payeeID,
                    column: "name",
                    value: .string(trimmedName)
                )
            )
            if payeeColumns.contains("tombstone") {
                messages.append(
                    builder.makeMessage(
                        dataset: "payees",
                        row: payeeID,
                        column: "tombstone",
                        value: .bool(false)
                    )
                )
            }

            if try tableExists("payee_mapping", db: db) {
                _ = try requiredColumns(table: "payee_mapping", required: ["targetId"], db: db)
                messages.append(
                    builder.makeMessage(
                        dataset: "payee_mapping",
                        row: payeeID,
                        column: "targetId",
                        value: .string(payeeID)
                    )
                )
            }
        }
        return (payeeID, messages)
    }

    func createSimpleTransactionMessages(
        _ draft: TransactionDraft,
        transactionID: String,
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try validateSimpleTransactionDraft(draft)
        var messages: [ActualSyncDecodedMessage] = []
        try queue.read { db in
            let columns = try requiredColumns(
                table: "transactions",
                required: ["date", "amount"],
                db: db
            )
            let accountColumn = try firstExistingColumn(["acct", "account"], in: columns, table: "transactions")
            let payeeColumn = try firstExistingColumn(["description", "payee"], in: columns, table: "transactions")
            let isParentColumn = columns.contains("is_parent") ? "is_parent" : (columns.contains("isParent") ? "isParent" : nil)
            let dateValue = try Self.actualDateValue(draft.date)

            messages.append(
                builder.makeMessage(
                    dataset: "transactions",
                    row: transactionID,
                    column: accountColumn,
                    value: .string(draft.accountID)
                )
            )
            messages.append(
                builder.makeMessage(
                    dataset: "transactions",
                    row: transactionID,
                    column: "date",
                    value: .int(Int64(dateValue))
                )
            )
            messages.append(
                builder.makeMessage(
                    dataset: "transactions",
                    row: transactionID,
                    column: "amount",
                    value: .int(Int64(draft.amountMinorUnits))
                )
            )
            messages.append(
                builder.makeMessage(
                    dataset: "transactions",
                    row: transactionID,
                    column: payeeColumn,
                    value: .string(payeeID)
                )
            )
            messages.append(
                builder.makeMessage(
                    dataset: "transactions",
                    row: transactionID,
                    column: "category",
                    value: draft.categoryID.map(LocalFirstSyncValue.string) ?? .null
                )
            )
            if columns.contains("notes") {
                messages.append(
                    builder.makeMessage(
                        dataset: "transactions",
                        row: transactionID,
                        column: "notes",
                        value: draft.notes.map(LocalFirstSyncValue.string) ?? .null
                    )
                )
            }
            if columns.contains("cleared") {
                messages.append(
                    builder.makeMessage(
                        dataset: "transactions",
                        row: transactionID,
                        column: "cleared",
                        value: .bool(draft.cleared)
                    )
                )
            }
            if columns.contains("tombstone") {
                messages.append(
                    builder.makeMessage(
                        dataset: "transactions",
                        row: transactionID,
                        column: "tombstone",
                        value: .bool(false)
                    )
                )
            }
            if let isParentColumn {
                messages.append(
                    builder.makeMessage(
                        dataset: "transactions",
                        row: transactionID,
                        column: isParentColumn,
                        value: .bool(false)
                    )
                )
            }
            if columns.contains("parent_id") {
                messages.append(
                    builder.makeMessage(
                        dataset: "transactions",
                        row: transactionID,
                        column: "parent_id",
                        value: .null
                    )
                )
            }
        }
        return messages
    }

    func updateSimpleTransactionMessages(
        transactionID: String,
        draft: TransactionDraft,
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try validateSimpleTransactionDraft(draft)
        let trimmedTransactionID = transactionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTransactionID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }

        return try queue.read { db in
            let columns = try requiredColumns(
                table: "transactions",
                required: ["date", "amount", "category"],
                db: db
            )
            guard try rowExists(table: "transactions", rowID: trimmedTransactionID, db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing transaction")
            }

            let accountColumn = try firstExistingColumn(["acct", "account"], in: columns, table: "transactions")
            let payeeColumn = try firstExistingColumn(["description", "payee"], in: columns, table: "transactions")
            try validateSimpleTransactionRow(
                transactionID: trimmedTransactionID,
                columns: columns,
                payeeColumn: payeeColumn,
                db: db
            )
            try validateSimpleTransactionReferences(draft: draft, payeeID: payeeID, db: db)

            let dateValue = try Self.actualDateValue(draft.date)
            var messages: [ActualSyncDecodedMessage] = [
                builder.makeMessage(
                    dataset: "transactions",
                    row: trimmedTransactionID,
                    column: accountColumn,
                    value: .string(draft.accountID)
                ),
                builder.makeMessage(
                    dataset: "transactions",
                    row: trimmedTransactionID,
                    column: "date",
                    value: .int(Int64(dateValue))
                ),
                builder.makeMessage(
                    dataset: "transactions",
                    row: trimmedTransactionID,
                    column: "amount",
                    value: .int(Int64(draft.amountMinorUnits))
                ),
                builder.makeMessage(
                    dataset: "transactions",
                    row: trimmedTransactionID,
                    column: payeeColumn,
                    value: .string(payeeID)
                ),
                builder.makeMessage(
                    dataset: "transactions",
                    row: trimmedTransactionID,
                    column: "category",
                    value: draft.categoryID.map(LocalFirstSyncValue.string) ?? .null
                )
            ]
            if columns.contains("notes") {
                messages.append(
                    builder.makeMessage(
                        dataset: "transactions",
                        row: trimmedTransactionID,
                        column: "notes",
                        value: draft.notes.map(LocalFirstSyncValue.string) ?? .null
                    )
                )
            }
            if columns.contains("cleared") {
                messages.append(
                    builder.makeMessage(
                        dataset: "transactions",
                        row: trimmedTransactionID,
                        column: "cleared",
                        value: .bool(draft.cleared)
                    )
                )
            }
            return messages
        }
    }

    func categorizeTransactionMessages(
        transactionID: String,
        categoryID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedTransactionID = transactionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCategoryID = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTransactionID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        guard !trimmedCategoryID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }

        return try queue.read { db in
            let transactionColumns = try requiredColumns(
                table: "transactions",
                required: ["category"],
                db: db
            )
            guard try rowExists(table: "transactions", rowID: trimmedTransactionID, db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing transaction")
            }

            let payeeColumn = try firstExistingColumn(["description", "payee"], in: transactionColumns, table: "transactions")
            try validateSimpleTransactionRow(
                transactionID: trimmedTransactionID,
                columns: transactionColumns,
                payeeColumn: payeeColumn,
                db: db
            )
            if try tableExists("categories", db: db),
               try !rowExists(table: "categories", rowID: trimmedCategoryID, db: db) {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }

            return [
                builder.makeMessage(
                    dataset: "transactions",
                    row: trimmedTransactionID,
                    column: "category",
                    value: .string(trimmedCategoryID)
                )
            ]
        }
    }

    /// Build the tombstone message that soft-deletes a simple transaction. Actual represents
    /// deletes as `tombstone = true` so read queries (which filter live rows) stop returning it
    /// and the delete converges through CRDT sync. Split and transfer rows are rejected because
    /// their deletes require paired/child handling that lands in later phases.
    func deleteSimpleTransactionMessages(
        transactionID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedTransactionID = transactionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTransactionID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }

        return try queue.read { db in
            let columns = try requiredColumns(
                table: "transactions",
                required: ["tombstone"],
                db: db
            )
            guard try rowExists(table: "transactions", rowID: trimmedTransactionID, db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing transaction")
            }

            let payeeColumn = try firstExistingColumn(["description", "payee"], in: columns, table: "transactions")
            try validateSimpleTransactionRow(
                transactionID: trimmedTransactionID,
                columns: columns,
                payeeColumn: payeeColumn,
                db: db
            )

            return [
                builder.makeMessage(
                    dataset: "transactions",
                    row: trimmedTransactionID,
                    column: "tombstone",
                    value: .bool(true)
                )
            ]
        }
    }

    private func accountBalances() throws -> [String: Int] {
        try queue.read { db in
            guard try tableExists("transactions", db: db) else {
                return [:]
            }

            let columns = try columnSet(for: "transactions", db: db)
            let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
            let amount = column("amount", fallback: "0", columns: columns)
            let parentPredicate = parentTransactionPredicate(columns: columns)
            let sql = """
                SELECT \(account) AS account_id, SUM(\(amount)) AS balance
                FROM transactions
                WHERE \(predicateForLiveRows(columns: columns)) AND \(parentPredicate)
                GROUP BY \(account)
                """
            let rows = try Row.fetchAll(db, sql: sql)
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let accountID = row["account_id"] as String? else {
                    return nil
                }
                return (accountID, actualAmountToMinorUnits(row["balance"] ?? 0))
            })
        }
    }

    /// Net balance of all on-budget accounts using only transactions dated on or before the
    /// given month. Sums split children (never the parent) so split totals aren't double
    /// counted, and excludes tombstoned rows and children of tombstoned parents.
    private func onBudgetAccountBalance(through month: String, db: Database) throws -> Int {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return 0
        }

        let columns = try columnSet(for: "transactions", db: db)
        let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        let date = column("date", fallback: "NULL", columns: columns)
        let parentID = column("parent_id", fallback: "NULL", columns: columns)
        let isParent = column("isParent", fallback: column("is_parent", fallback: "0", columns: columns), columns: columns)
        let budgetMonth = normalizedMonthExpression("t.\(date)")
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT SUM(t.\(amount)) AS balance
                FROM transactions t
                LEFT JOIN accounts a ON a.id = t.\(account)
                LEFT JOIN transactions p ON p.id = t.\(parentID)
                WHERE \(predicateForLiveRows(columns: columns, tableAlias: "t"))
                  AND (t.\(parentID) IS NULL OR p.tombstone = 0 OR p.tombstone IS NULL)
                  AND (t.\(isParent) = 0 OR t.\(isParent) IS NULL)
                  AND a.offbudget = 0
                  AND \(budgetMonth) <= ?
                """,
            arguments: [month]
        )
        return actualAmountToMinorUnits(row?["balance"] ?? 0)
    }

    private func uncategorizedOnBudgetActivity(through month: String, db: Database) throws -> Int {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return 0
        }

        let columns = try columnSet(for: "transactions", db: db)
        let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
        let category = column("category", fallback: "NULL", columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        let date = column("date", fallback: "NULL", columns: columns)
        let parentID = column("parent_id", fallback: "NULL", columns: columns)
        let isParent = column("isParent", fallback: column("is_parent", fallback: "0", columns: columns), columns: columns)
        let budgetMonth = normalizedMonthExpression("t.\(date)")
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT SUM(t.\(amount)) AS amount
                FROM transactions t
                LEFT JOIN accounts a ON a.id = t.\(account)
                LEFT JOIN transactions p ON p.id = t.\(parentID)
                WHERE \(predicateForLiveRows(columns: columns, tableAlias: "t"))
                  AND (t.\(parentID) IS NULL OR p.tombstone = 0 OR p.tombstone IS NULL)
                  AND (t.\(isParent) = 0 OR t.\(isParent) IS NULL)
                  AND (t.\(category) IS NULL OR t.\(category) = '')
                  AND a.offbudget = 0
                  AND \(budgetMonth) <= ?
                """,
            arguments: [month]
        )
        return actualAmountToMinorUnits(row?["amount"] ?? 0)
    }

    private func fetchCategoryGroups(
        categoryValues: [String: EnvelopeCategoryValue],
        db: Database
    ) throws -> [BudgetMonthCategoryGroup] {
        guard try tableExists("category_groups", db: db) else {
            return []
        }

        let groupColumns = try columnSet(for: "category_groups", db: db)
        let groupHidden = column("hidden", fallback: "0", columns: groupColumns)
        let groupIncome = column("is_income", fallback: "0", columns: groupColumns)
        let groupOrder = groupColumns.contains("sort_order") ? "sort_order, lower(name)" : "lower(name)"
        let groupRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, \(groupIncome) AS is_income, \(groupHidden) AS hidden
                FROM category_groups
                WHERE \(predicateForLiveRows(columns: groupColumns))
                ORDER BY \(groupOrder)
                """
        )

        return try groupRows.map { groupRow in
            let groupID: String = groupRow["id"] ?? ""
            let categories = try fetchBudgetCategories(groupID: groupID, categoryValues: categoryValues, db: db)
            return BudgetMonthCategoryGroup(
                id: groupID,
                name: groupRow["name"] ?? "",
                isIncome: flexibleBool(groupRow["is_income"]),
                hidden: flexibleBool(groupRow["hidden"]),
                budgeted: categories.reduce(0) { $0 + $1.budgeted },
                spent: categories.reduce(0) { $0 + $1.spent },
                balance: categories.reduce(0) { $0 + $1.balance },
                categories: categories
            )
        }
    }

    private func fetchBudgetCategories(
        groupID: String,
        categoryValues: [String: EnvelopeCategoryValue],
        db: Database
    ) throws -> [BudgetMonthCategory] {
        guard try tableExists("categories", db: db) else {
            return []
        }

        let categoryColumns = try columnSet(for: "categories", db: db)
        let groupColumn = column("cat_group", fallback: column("group_id", fallback: "NULL", columns: categoryColumns), columns: categoryColumns)
        let categoryHidden = column("hidden", fallback: "0", columns: categoryColumns)
        let categoryIncome = column("is_income", fallback: "0", columns: categoryColumns)
        let categoryOrder = categoryColumns.contains("sort_order") ? "sort_order, lower(name)" : "lower(name)"
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, \(categoryIncome) AS is_income, \(categoryHidden) AS hidden, \(groupColumn) AS group_id
                FROM categories
                WHERE \(predicateForLiveRows(columns: categoryColumns)) AND \(groupColumn) = ?
                ORDER BY \(categoryOrder)
                """,
            arguments: [groupID]
        )

        return rows.map { row in
            let id: String = row["id"] ?? ""
            let values = categoryValues[id] ?? EnvelopeCategoryValue()
            return BudgetMonthCategory(
                id: id,
                name: row["name"] ?? "",
                isIncome: flexibleBool(row["is_income"]),
                hidden: flexibleBool(row["hidden"]),
                groupID: row["group_id"] ?? groupID,
                budgeted: values.budgeted,
                spent: values.spent,
                balance: values.balance,
                carryover: values.carryover
            )
        }
    }

    private func envelopeCategoryValues(through month: String, db: Database) throws -> [String: EnvelopeCategoryValue] {
        let budgetedByMonth = try categoryBudgetsByMonth(db: db)
        let spentByMonth = try categorySpendingByMonth(db: db)
        let targetMonthInt = monthInt(month)
        let earliestMonthInt = Array(Set(budgetedByMonth.keys).union(spentByMonth.keys))
            .compactMap(monthInt)
            .filter { $0 <= targetMonthInt }
            .min() ?? targetMonthInt

        var previousBalanceByCategory: [String: Int] = [:]
        var previousCarryoverByCategory: [String: Bool] = [:]
        var targetValues: [String: EnvelopeCategoryValue] = [:]

        var monthCursor = earliestMonthInt
        while monthCursor <= targetMonthInt {
            let budgetMonth = monthID(monthCursor)
            let budgeted = budgetedByMonth[budgetMonth] ?? [:]
            let spent = spentByMonth[budgetMonth] ?? [:]
            let categoryIDs = Set(budgeted.keys).union(spent.keys).union(previousBalanceByCategory.keys)
            var nextBalanceByCategory: [String: Int] = [:]
            var nextCarryoverByCategory: [String: Bool] = [:]

            for categoryID in categoryIDs {
                let budget = budgeted[categoryID] ?? (budgeted: 0, carryover: false)
                let spentAmount = spent[categoryID] ?? 0
                let previousBalance = previousBalanceByCategory[categoryID] ?? 0
                let previousContribution = previousCarryoverByCategory[categoryID] == true
                    ? previousBalance
                    : max(0, previousBalance)
                let balance = budget.budgeted + spentAmount + previousContribution
                nextBalanceByCategory[categoryID] = balance
                nextCarryoverByCategory[categoryID] = budget.carryover

                if budgetMonth == month {
                    targetValues[categoryID] = EnvelopeCategoryValue(
                        budgeted: budget.budgeted,
                        spent: spentAmount,
                        balance: balance,
                        carryover: budget.carryover
                    )
                }
            }

            previousBalanceByCategory = nextBalanceByCategory
            previousCarryoverByCategory = nextCarryoverByCategory
            monthCursor = nextMonth(after: monthCursor)
        }

        return targetValues
    }

    private func categoryBudgets(month: String, db: Database) throws -> [String: (budgeted: Int, carryover: Bool)] {
        guard try tableExists("zero_budgets", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "zero_budgets", db: db)
        let category = column("category", fallback: "NULL", columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        let carryover = column("carryover", fallback: "0", columns: columns)
        let budgetMonth = normalizedMonthExpression("month")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(category) AS category_id, \(amount) AS amount, \(carryover) AS carryover
                FROM zero_budgets
                WHERE \(budgetMonth) = ?
                """,
            arguments: [month]
        )
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let categoryID = row["category_id"] as String? else {
                return nil
            }
            return (
                categoryID,
                (
                    budgeted: actualAmountToMinorUnits(row["amount"] ?? 0),
                    carryover: flexibleBool(row["carryover"])
                )
            )
        })
    }

    private func categoryBudgetsByMonth(db: Database) throws -> [String: [String: (budgeted: Int, carryover: Bool)]] {
        guard try tableExists("zero_budgets", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "zero_budgets", db: db)
        let category = column("category", fallback: "NULL", columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        let carryover = column("carryover", fallback: "0", columns: columns)
        let budgetMonth = normalizedMonthExpression("month")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(budgetMonth) AS month, \(category) AS category_id, \(amount) AS amount, \(carryover) AS carryover
                FROM zero_budgets
                WHERE month IS NOT NULL
                """
        )
        return rows.reduce(into: [:]) { result, row in
            guard
                let month = flexibleString(row["month"]),
                let categoryID = row["category_id"] as String?
            else {
                return
            }
            result[month, default: [:]][categoryID] = (
                budgeted: actualAmountToMinorUnits(row["amount"] ?? 0),
                carryover: flexibleBool(row["carryover"])
            )
        }
    }

    private func categorySpending(month: String, db: Database) throws -> [String: Int] {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "transactions", db: db)
        let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
        let category = column("category", fallback: "NULL", columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        let date = column("date", fallback: "NULL", columns: columns)
        let parentID = column("parent_id", fallback: "NULL", columns: columns)
        let isParent = column("isParent", fallback: column("is_parent", fallback: "0", columns: columns), columns: columns)
        let categoryMappingJoin = try tableExists("category_mapping", db: db)
            ? "LEFT JOIN category_mapping cm ON cm.id = t.\(category)"
            : ""
        let mappedCategory = try tableExists("category_mapping", db: db)
            ? "COALESCE(cm.transferId, t.\(category))"
            : "t.\(category)"
        let budgetMonth = normalizedMonthExpression("t.\(date)")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(mappedCategory) AS category_id, SUM(t.\(amount)) AS amount
                FROM transactions t
                \(categoryMappingJoin)
                LEFT JOIN accounts a ON a.id = t.\(account)
                LEFT JOIN transactions p ON p.id = t.\(parentID)
                WHERE \(predicateForLiveRows(columns: columns, tableAlias: "t"))
                  AND (t.\(parentID) IS NULL OR p.tombstone = 0 OR p.tombstone IS NULL)
                  AND (t.\(isParent) = 0 OR t.\(isParent) IS NULL)
                  AND t.\(category) IS NOT NULL
                  AND a.offbudget = 0
                  AND \(budgetMonth) = ?
                GROUP BY \(mappedCategory)
                """,
            arguments: [month]
        )
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let categoryID = row["category_id"] as String? else {
                return nil
            }
            return (categoryID, actualAmountToMinorUnits(row["amount"] ?? 0))
        })
    }

    private func categorySpendingByMonth(db: Database) throws -> [String: [String: Int]] {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "transactions", db: db)
        let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
        let category = column("category", fallback: "NULL", columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        let date = column("date", fallback: "NULL", columns: columns)
        let parentID = column("parent_id", fallback: "NULL", columns: columns)
        let isParent = column("isParent", fallback: column("is_parent", fallback: "0", columns: columns), columns: columns)
        let categoryMappingJoin = try tableExists("category_mapping", db: db)
            ? "LEFT JOIN category_mapping cm ON cm.id = t.\(category)"
            : ""
        let mappedCategory = try tableExists("category_mapping", db: db)
            ? "COALESCE(cm.transferId, t.\(category))"
            : "t.\(category)"
        let budgetMonth = normalizedMonthExpression("t.\(date)")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(budgetMonth) AS month, \(mappedCategory) AS category_id, SUM(t.\(amount)) AS amount
                FROM transactions t
                \(categoryMappingJoin)
                LEFT JOIN accounts a ON a.id = t.\(account)
                LEFT JOIN transactions p ON p.id = t.\(parentID)
                WHERE \(predicateForLiveRows(columns: columns, tableAlias: "t"))
                  AND (t.\(parentID) IS NULL OR p.tombstone = 0 OR p.tombstone IS NULL)
                  AND (t.\(isParent) = 0 OR t.\(isParent) IS NULL)
                  AND t.\(category) IS NOT NULL
                  AND a.offbudget = 0
                GROUP BY \(budgetMonth), \(mappedCategory)
                """
        )
        return rows.reduce(into: [:]) { result, row in
            guard
                let month = flexibleString(row["month"]),
                let categoryID = row["category_id"] as String?
            else {
                return
            }
            result[month, default: [:]][categoryID] = actualAmountToMinorUnits(row["amount"] ?? 0)
        }
    }

    private func monthInt(_ month: String) -> Int {
        Int(month.replacingOccurrences(of: "-", with: "")) ?? 0
    }

    private func monthID(_ month: Int) -> String {
        let year = month / 100
        let monthNumber = month % 100
        return String(format: "%04d-%02d", year, monthNumber)
    }

    private func nextMonth(after month: Int) -> Int {
        let year = month / 100
        let monthNumber = month % 100
        if monthNumber == 12 {
            return (year + 1) * 100 + 1
        }
        return year * 100 + monthNumber + 1
    }

    private func transactionBudgetSource(db: Database) throws -> TransactionBudgetSource {
        if try tableExists("v_transactions_internal_alive", db: db) {
            return TransactionBudgetSource(
                tableExists: true,
                table: "v_transactions_internal_alive",
                account: "account",
                category: "t.category",
                amount: "t.amount",
                month: normalizedMonthExpression("t.date"),
                livePredicate: "1 = 1"
            )
        }

        guard try tableExists("transactions", db: db) else {
            return TransactionBudgetSource(
                tableExists: false,
                table: "transactions",
                account: "acct",
                category: "category",
                amount: "amount",
                month: normalizedMonthExpression("date"),
                livePredicate: "1 = 0"
            )
        }

        let columns = try columnSet(for: "transactions", db: db)
        let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
        let category = column("category", fallback: "NULL", columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        return TransactionBudgetSource(
            tableExists: true,
            table: "transactions",
            account: account,
            category: "t.\(category)",
            amount: "t.\(amount)",
            month: normalizedMonthExpression("t.date"),
            livePredicate: "\(predicateForLiveRows(columns: columns, tableAlias: "t")) AND \(parentTransactionPredicate(columns: columns, tableAlias: "t"))"
        )
    }

    private func hasSameOrNewerMessage(_ message: ActualSyncDecodedMessage, db: Database) throws -> Bool {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT timestamp FROM messages_crdt
                WHERE dataset = ? AND row = ? AND column = ? AND timestamp >= ?
                ORDER BY timestamp ASC
                LIMIT 1
                """,
            arguments: [message.dataset, message.row, message.column, message.timestamp]
        )
        return row != nil
    }

    private func validateLocalMessage(_ message: ActualSyncDecodedMessage, db: Database) throws {
        guard try tableExists(message.dataset, db: db) else {
            throw LocalFirstError.invalidLocalWrite("unknown dataset \(message.dataset)")
        }
        let columns = try columnSet(for: message.dataset, db: db)
        guard columns.contains(message.column) else {
            throw LocalFirstError.invalidLocalWrite("unknown column \(message.dataset).\(message.column)")
        }
    }

    private func validateSimpleTransactionRow(
        transactionID: String,
        columns: Set<String>,
        payeeColumn: String,
        db: Database
    ) throws {
        let isParentColumn = column(
            "is_parent",
            fallback: column("isParent", fallback: "0", columns: columns),
            columns: columns
        )
        if let isParent = try Int.fetchOne(
            db,
            sql: "SELECT \(isParentColumn) FROM transactions WHERE id = ?",
            arguments: [transactionID]
        ), isParent != 0 {
            throw LocalFirstError.unsupportedSplitWrite
        }
        if columns.contains("parent_id"),
           let parentID = try String.fetchOne(
            db,
            sql: "SELECT parent_id FROM transactions WHERE id = ?",
            arguments: [transactionID]
           ),
           !parentID.isEmpty {
            throw LocalFirstError.unsupportedSplitWrite
        }
        if try tableExists("payees", db: db),
           let payeeID = try String.fetchOne(
            db,
            sql: "SELECT \(payeeColumn) FROM transactions WHERE id = ?",
            arguments: [transactionID]
           ) {
            try validatePayeeIsNotTransfer(payeeID: payeeID, db: db)
        }
    }

    private func validateSimpleTransactionReferences(
        draft: TransactionDraft,
        payeeID: String,
        db: Database
    ) throws {
        if try tableExists("accounts", db: db),
           try !rowExists(table: "accounts", rowID: draft.accountID, db: db) {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }
        if let categoryID = draft.categoryID,
           try tableExists("categories", db: db),
           try !rowExists(table: "categories", rowID: categoryID, db: db) {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
        if try tableExists("payees", db: db) {
            guard try rowExists(table: "payees", rowID: payeeID, db: db) else {
                return
            }
            try validatePayeeIsNotTransfer(payeeID: payeeID, db: db)
        }
    }

    private func validatePayeeIsNotTransfer(payeeID: String, db: Database) throws {
        guard try tableExists("payees", db: db) else {
            return
        }
        let payeeColumns = try columnSet(for: "payees", db: db)
        let transferColumn = column(
            "transfer_acct",
            fallback: column("transferAccount", fallback: "NULL", columns: payeeColumns),
            columns: payeeColumns
        )
        guard transferColumn != "NULL" else {
            return
        }
        if let transferAccount = try String.fetchOne(
            db,
            sql: "SELECT \(transferColumn) FROM payees WHERE id = ?",
            arguments: [payeeID]
        ), !transferAccount.isEmpty {
            throw LocalFirstError.unsupportedTransferWrite
        }
    }

    private func validateSimpleTransactionDraft(_ draft: TransactionDraft) throws {
        guard !draft.isSplit else {
            throw LocalFirstError.unsupportedSplitWrite
        }
        guard !draft.isTransfer else {
            throw LocalFirstError.unsupportedTransferWrite
        }
        guard !draft.accountID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }
        guard draft.amountMinorUnits != 0 else {
            throw LocalFirstError.invalidLocalWrite("missing amount")
        }
    }

    private func requiredColumns(
        table: String,
        required: [String],
        db: Database
    ) throws -> Set<String> {
        guard try tableExists(table, db: db) else {
            throw LocalFirstError.invalidLocalWrite("missing \(table) table")
        }
        let columns = try columnSet(for: table, db: db)
        for column in required where !columns.contains(column) {
            throw LocalFirstError.invalidLocalWrite("missing column \(table).\(column)")
        }
        return columns
    }

    private func firstExistingColumn(
        _ candidates: [String],
        in columns: Set<String>,
        table: String
    ) throws -> String {
        for candidate in candidates where columns.contains(candidate) {
            return candidate
        }
        throw LocalFirstError.invalidLocalWrite("missing column \(table).\(candidates.joined(separator: "|"))")
    }

    private func rowExists(table: String, rowID: String, db: Database) throws -> Bool {
        try Row.fetchOne(
            db,
            sql: "SELECT id FROM \(quotedIdentifier(table)) WHERE id = ? LIMIT 1",
            arguments: [rowID]
        ) != nil
    }

    private func apply(
        message: ActualSyncDecodedMessage,
        value: ActualSyncSQLiteValue,
        rowExists: Bool,
        db: Database
    ) throws {
        let table = quotedIdentifier(message.dataset)
        let column = quotedIdentifier(message.column)
        if rowExists {
            switch value {
            case .null:
                try db.execute(
                    sql: "UPDATE \(table) SET \(column) = NULL WHERE id = ?",
                    arguments: [message.row]
                )
            case .int(let value):
                try db.execute(
                    sql: "UPDATE \(table) SET \(column) = ? WHERE id = ?",
                    arguments: [value, message.row]
                )
            case .double(let value):
                try db.execute(
                    sql: "UPDATE \(table) SET \(column) = ? WHERE id = ?",
                    arguments: [value, message.row]
                )
            case .string(let value):
                try db.execute(
                    sql: "UPDATE \(table) SET \(column) = ? WHERE id = ?",
                    arguments: [value, message.row]
                )
            }
        } else {
            switch value {
            case .null:
                try db.execute(
                    sql: "INSERT INTO \(table) (id, \(column)) VALUES (?, NULL)",
                    arguments: [message.row]
                )
            case .int(let value):
                try db.execute(
                    sql: "INSERT INTO \(table) (id, \(column)) VALUES (?, ?)",
                    arguments: [message.row, value]
                )
            case .double(let value):
                try db.execute(
                    sql: "INSERT INTO \(table) (id, \(column)) VALUES (?, ?)",
                    arguments: [message.row, value]
                )
            case .string(let value):
                try db.execute(
                    sql: "INSERT INTO \(table) (id, \(column)) VALUES (?, ?)",
                    arguments: [message.row, value]
                )
            }
        }
    }

    private func insertCRDTMessage(_ message: ActualSyncDecodedMessage, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO messages_crdt (timestamp, dataset, row, column, value)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                message.timestamp,
                message.dataset,
                message.row,
                message.column,
                message.serializedValue
            ]
        )
    }

    private func deserializeSyncValue(_ value: String) throws -> ActualSyncSQLiteValue {
        guard let type = value.first else {
            throw LocalFirstError.invalidDownloadedBudget
        }
        let payload = String(value.dropFirst(2))
        switch type {
        case "0":
            return .null
        case "N":
            guard let number = Double(payload) else {
                throw LocalFirstError.invalidDownloadedBudget
            }
            if number.rounded() == number {
                return .int(Int64(number))
            }
            return .double(number)
        case "S":
            return .string(payload)
        default:
            throw LocalFirstError.invalidDownloadedBudget
        }
    }

    private func quotedIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func tableExists(_ table: String, db: Database) throws -> Bool {
        try Row.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        ) != nil
    }

    private func columnSet(for table: String, db: Database) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return Set(rows.compactMap { $0["name"] as String? })
    }

    private func column(_ name: String, fallback: String, columns: Set<String>) -> String {
        columns.contains(name) ? name : fallback
    }

    private func predicateForLiveRows(columns: Set<String>) -> String {
        if columns.contains("tombstone") {
            return "(tombstone IS NULL OR tombstone = 0)"
        }
        if columns.contains("deleted") {
            return "(deleted IS NULL OR deleted = 0)"
        }
        return "1 = 1"
    }

    private func predicateForLiveRows(columns: Set<String>, tableAlias: String) -> String {
        if columns.contains("tombstone") {
            return "(\(tableAlias).tombstone IS NULL OR \(tableAlias).tombstone = 0)"
        }
        if columns.contains("deleted") {
            return "(\(tableAlias).deleted IS NULL OR \(tableAlias).deleted = 0)"
        }
        return "1 = 1"
    }

    private func parentTransactionPredicate(columns: Set<String>) -> String {
        var predicates: [String] = []
        if columns.contains("parent_id") {
            predicates.append("parent_id IS NULL")
        }
        if columns.contains("is_child") {
            predicates.append("(is_child IS NULL OR is_child = 0)")
        }
        if columns.contains("is_parent") {
            predicates.append("(is_parent IS NULL OR is_parent = 0)")
        }
        return predicates.isEmpty ? "1 = 1" : predicates.joined(separator: " AND ")
    }

    private func parentTransactionPredicate(columns: Set<String>, tableAlias: String) -> String {
        var predicates: [String] = []
        if columns.contains("parent_id") {
            predicates.append("\(tableAlias).parent_id IS NULL")
        }
        if columns.contains("is_child") {
            predicates.append("(\(tableAlias).is_child IS NULL OR \(tableAlias).is_child = 0)")
        }
        if columns.contains("is_parent") {
            predicates.append("(\(tableAlias).is_parent IS NULL OR \(tableAlias).is_parent = 0)")
        }
        return predicates.isEmpty ? "1 = 1" : predicates.joined(separator: " AND ")
    }

    /// Converts an Actual integer date (yyyyMMdd, e.g. 20260703) into a "yyyy-MM-dd" string.
    private func normalizedDateExpression(_ column: String) -> String {
        let text = "CAST(\(column) AS TEXT)"
        return """
            CASE
                WHEN length(\(text)) = 8
                    THEN substr(\(text), 1, 4) || '-' || substr(\(text), 5, 2) || '-' || substr(\(text), 7, 2)
                ELSE \(text)
            END
            """
    }

    private func normalizedMonthExpression(_ column: String) -> String {
        let text = "CAST(\(column) AS TEXT)"
        return """
            CASE
                WHEN length(\(text)) = 6 THEN substr(\(text), 1, 4) || '-' || substr(\(text), 5, 2)
                WHEN length(\(text)) = 8 THEN substr(\(text), 1, 4) || '-' || substr(\(text), 5, 2)
                ELSE substr(\(text), 1, 7)
            END
            """
    }

    private func flexibleString(_ value: DatabaseValueConvertible?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? Int {
            return String(value)
        }
        if let value = value as? Int64 {
            return String(value)
        }
        return nil
    }

    private func flexibleBool(_ value: DatabaseValueConvertible?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? Int {
            return value != 0
        }
        if let value = value as? Int64 {
            return value != 0
        }
        if let value = value as? String {
            return ["1", "true", "yes"].contains(value.lowercased())
        }
        return false
    }

    private func actualAmountToMinorUnits(_ amount: Int) -> Int {
        amount
    }

    private static func actualDateValue(_ date: Date) throws -> Int {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            throw LocalFirstError.invalidLocalWrite("invalid transaction date")
        }
        return year * 10_000 + month * 100 + day
    }
}
