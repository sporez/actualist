import Foundation
import GRDB

extension BudgetDatabase {

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
            let bank = column("bank", fallback: "NULL", columns: columns)
            let accountSyncSource = column(
                "account_sync_source",
                fallback: column("bank_sync_source", fallback: "NULL", columns: columns),
                columns: columns
            )
            let bankSyncStatus = column("bank_sync_status", fallback: "NULL", columns: columns)
            let accountGroupID = column("account_group_id", fallback: "NULL", columns: columns)
            let tombstonePredicate = predicateForLiveRows(columns: columns)
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

    func fetchAccountGroups() throws -> [ActualAccountGroup] {
        try queue.read { db in
            guard try tableExists("account_groups", db: db) else {
                return []
            }

            let columns = try columnSet(for: "account_groups", db: db)
            let name = column("name", fallback: "''", columns: columns)
            let sortOrder = column("sort_order", fallback: "0", columns: columns)
            let order = columns.contains("sort_order") ? "sort_order, id" : "id"
            let sql = """
                SELECT id, \(name) AS name, \(sortOrder) AS sort_order
                FROM account_groups
                WHERE \(predicateForLiveRows(columns: columns))
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
                    isIncome: SQLiteValueCoercion.lenientBool(row["is_income"]),
                    hidden: SQLiteValueCoercion.lenientBool(row["hidden"]),
                    groupID: row["group_id"]
                )
            }
        }
    }

    func fetchAvailableMonths() throws -> [String] {
        try queue.read { db in try fetchAvailableMonths(db: db) }
    }

    func fetchAvailableMonths(db: Database) throws -> [String] {
        var months = Set<String>()
        let table = try budgetTable(db: db).rawValue
        if try tableExists(table, db: db), try columnSet(for: table, db: db).contains("month") {
            let normalizedMonth = normalizedMonthExpression("month")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT \(normalizedMonth) AS month
                    FROM \(quotedIdentifier(table))
                    WHERE month IS NOT NULL
                    """
            )
            months.formUnion(rows.compactMap { YearMonth.canonicalID(SQLiteValueCoercion.lenientString($0["month"])) })
        }
        if try tableExists("transactions", db: db), try columnSet(for: "transactions", db: db).contains("date") {
            let columns = try columnSet(for: "transactions", db: db)
            // Envelope keeps deleted rows' months: upstream sizes the month range from the
            // earliest row of the raw `transactions` table (`createAllBudgets`, budget/base.ts),
            // tombstones included. Tracking filters them here, which upstream does not do.
            let live = table == BudgetTable.tracking.rawValue ? predicateForLiveRows(columns: columns) : "1 = 1"
            let normalizedMonth = normalizedMonthExpression("date")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT \(normalizedMonth) AS month
                    FROM transactions
                    WHERE date IS NOT NULL AND \(live)
                    """
            )
            months.formUnion(rows.compactMap { YearMonth.canonicalID(SQLiteValueCoercion.lenientString($0["month"])) })
        }
        return months.sorted()
    }

    func fetchAccountDisplays() throws -> [AccountDisplay] {
        let accounts = try fetchAccounts()
        let balances = try accountBalances()
        let userNoteIDs = try fetchUserNoteIDs(
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
}
