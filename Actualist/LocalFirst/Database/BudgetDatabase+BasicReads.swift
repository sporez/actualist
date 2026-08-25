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
                    offbudget: flexibleBool(row["offbudget"]),
                    closed: flexibleBool(row["closed"]),
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
                    sortOrder: flexibleDouble(row["sort_order"])
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
            let favorite = column("favorite", fallback: "0", columns: columns)
            let sql = """
                SELECT id, name, \(category) AS category, \(transferAccount) AS transfer_acct,
                       \(favorite) AS favorite
                FROM payees
                WHERE \(predicateForLiveRows(columns: columns))
                """
            let recentRanks = try recentCommonPayeeRanks(db: db)
            return try Row.fetchAll(db, sql: sql).map { row in
                (
                    payee: ActualPayee(
                    id: row["id"],
                    name: row["name"] ?? "",
                    category: row["category"],
                    transferAccount: row["transfer_acct"]
                    ),
                    favorite: flexibleBool(row["favorite"])
                )
            }
            .sorted { lhs, rhs in
                if lhs.payee.transferAccount != nil || rhs.payee.transferAccount != nil {
                    if (lhs.payee.transferAccount != nil) != (rhs.payee.transferAccount != nil) {
                        return lhs.payee.transferAccount == nil
                    }
                }
                if lhs.favorite != rhs.favorite {
                    return lhs.favorite
                }
                let lhsRank = lhs.payee.id.flatMap { recentRanks[$0] }
                let rhsRank = rhs.payee.id.flatMap { recentRanks[$0] }
                if lhsRank != rhsRank {
                    if let lhsRank, let rhsRank { return lhsRank < rhsRank }
                    return lhsRank != nil
                }
                return lhs.payee.name.localizedCaseInsensitiveCompare(rhs.payee.name) == .orderedAscending
            }
            .map(\.payee)
        }
    }

    private func recentCommonPayeeRanks(db: Database) throws -> [String: Int] {
        guard try tableExists("transactions", db: db) else { return [:] }
        let transactionColumns = try columnSet(for: "transactions", db: db)
        guard transactionColumns.contains("date"),
              let payeeColumn = ["description", "payee"].first(where: transactionColumns.contains) else {
            return [:]
        }
        let cutoff = Calendar(identifier: .iso8601).date(byAdding: .weekOfYear, value: -12, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
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
        let liveTransactions = predicateForLiveRows(columns: transactionColumns)
            .replacingOccurrences(of: "tombstone", with: "t.tombstone")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(resolvedPayee) AS payee_id, COUNT(*) AS usage_count
                FROM transactions t
                \(mappingJoin)
                WHERE \(liveTransactions)
                  AND \(normalizedDateExpression("t.\(quotedIdentifier("date"))")) > ?
                  AND \(rawPayee) IS NOT NULL
                GROUP BY \(resolvedPayee)
                ORDER BY usage_count DESC, payee_id
                LIMIT 10
                """,
            arguments: [formatter.string(from: cutoff)]
        )
        return Dictionary(uniqueKeysWithValues: rows.enumerated().compactMap { index, row in
            guard let id = row["payee_id"] as String? else { return nil }
            return (id, index)
        })
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
                let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT month FROM zero_budgets WHERE month IS NOT NULL")
                months.formUnion(rows.compactMap { canonicalMonthID(flexibleString($0["month"])) })
            }
            if try tableExists("transactions", db: db), try columnSet(for: "transactions", db: db).contains("date") {
                let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT date FROM transactions WHERE date IS NOT NULL")
                months.formUnion(rows.compactMap { canonicalMonthID(flexibleString($0["date"])) })
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
}
