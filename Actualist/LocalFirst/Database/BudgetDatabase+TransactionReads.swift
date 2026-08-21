import Foundation
import GRDB

extension BudgetDatabase {

    func fetchTransactions(accountID: String? = nil, matching query: String? = nil) throws -> [ActualTransaction] {
        try fetchTransactionPage(accountID: accountID, matching: query, limit: nil, offset: 0).transactions
    }

    func fetchTransactionPage(
        accountID: String? = nil,
        matching query: String? = nil,
        limit: Int?,
        offset: Int = 0
    ) throws -> TransactionFetchResult {
        try queue.read { db in
            guard try tableExists("transactions", db: db) else {
                return TransactionFetchResult(transactions: [], reachedEnd: true)
            }

            let columns = try columnSet(for: "transactions", db: db)
            // Missing columns need a bare SQL literal, not an invalid qualified literal.
            func expr(_ names: [String], fallback: String) -> String {
                for name in names where columns.contains(name) {
                    return "t.\(name)"
                }
                return fallback
            }
            let account = expr(["acct", "account"], fallback: "NULL")
            let date = expr(["date"], fallback: "NULL")
            let amount = expr(["amount"], fallback: "0")
            // `payee` is a view alias; the physical column is `description`.
            let payee = expr(["payee", "description"], fallback: "NULL")
            let category = expr(["category"], fallback: "NULL")
            let notes = expr(["notes"], fallback: "NULL")
            let cleared = expr(["cleared"], fallback: "0")
            let reconciled = expr(["reconciled"], fallback: "0")
            let importedPayee = expr(["imported_description", "imported_payee"], fallback: "NULL")
            let parentID = expr(["parent_id"], fallback: "NULL")
            let isParent = expr(["isParent", "is_parent"], fallback: "0")
            let normalizedDate = normalizedDateExpression(date)
            let hasCategoryMapping = try tableExists("category_mapping", db: db)
            let mappedCategory = hasCategoryMapping ? "COALESCE(cm.transferId, \(category))" : category
            let categoryMappingJoin = hasCategoryMapping ? "LEFT JOIN category_mapping cm ON cm.id = \(category)" : ""
            // Merged payees resolve through payee_mapping.
            let hasPayeeMapping = try tableExists("payee_mapping", db: db)
            let mappedPayee = hasPayeeMapping ? "COALESCE(pm.targetId, \(payee))" : payee
            let payeeMappingJoin = hasPayeeMapping ? "LEFT JOIN payee_mapping pm ON pm.id = \(payee)" : ""
            let hasPayees = try tableExists("payees", db: db)
            let hasAccounts = try tableExists("accounts", db: db)
            let payeeColumns = hasPayees ? try columnSet(for: "payees", db: db) : []
            // Transfer payees display the linked account name.
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
                conditions.append("(\(payeeNameSelect) LIKE ? ESCAPE '\\' OR \(notes) LIKE ? ESCAPE '\\' OR CAST(\(amount) AS TEXT) LIKE ? ESCAPE '\\')")
                let like = "%\(escapeLikePattern(query))%"
                arguments.append(contentsOf: [like, like, like])
            }

            let rowLimit = limit.map { max(1, $0) }
            let rowOffset = max(0, offset)
            let topLevelIDs: [String]?
            let reachedEnd: Bool
            if let rowLimit {
                var topLevelConditions = conditions
                topLevelConditions.append("\(parentID) IS NULL")
                var topLevelArguments = arguments
                topLevelArguments.append(rowLimit + 1)
                topLevelArguments.append(rowOffset)
                let topLevelSQL = """
                    SELECT t.id AS id
                    FROM transactions t
                    \(categoryMappingJoin)
                    \(payeeMappingJoin)
                    \(payeeNameJoin)
                    LEFT JOIN transactions p ON p.id = \(parentID)
                    WHERE \(topLevelConditions.joined(separator: " AND "))
                    ORDER BY \(normalizedDate) DESC, t.id DESC
                    LIMIT ? OFFSET ?
                    """
                let fetchedIDs = try Row.fetchAll(
                    db,
                    sql: topLevelSQL,
                    arguments: StatementArguments(topLevelArguments)
                ).compactMap { $0["id"] as String? }
                reachedEnd = fetchedIDs.count <= rowLimit
                topLevelIDs = Array(fetchedIDs.prefix(rowLimit))
                if topLevelIDs?.isEmpty != false {
                    return TransactionFetchResult(transactions: [], reachedEnd: true)
                }
            } else {
                topLevelIDs = nil
                reachedEnd = true
            }

            var rowConditions = conditions
            var rowArguments = arguments
            if let topLevelIDs {
                let placeholders = Array(repeating: "?", count: topLevelIDs.count).joined(separator: ", ")
                rowConditions = [
                    predicateForLiveRows(columns: columns, tableAlias: "t"),
                    "(\(parentID) IS NULL OR p.tombstone = 0 OR p.tombstone IS NULL)",
                    "(t.id IN (\(placeholders)) OR \(parentID) IN (\(placeholders)))"
                ]
                rowArguments = (topLevelIDs + topLevelIDs).map { $0 as DatabaseValueConvertible }
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
                       \(reconciled) AS reconciled,
                       \(parentID) AS parent_id,
                       \(isParent) AS is_parent
                FROM transactions t
                \(categoryMappingJoin)
                \(payeeMappingJoin)
                \(payeeNameJoin)
                LEFT JOIN transactions p ON p.id = \(parentID)
                WHERE \(rowConditions.joined(separator: " AND "))
                ORDER BY \(normalizedDate) DESC, t.id DESC
                """

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(rowArguments))
            return TransactionFetchResult(transactions: assembleTransactions(from: rows), reachedEnd: reachedEnd)
        }
    }

    func escapeLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    func assembleTransactions(from rows: [Row]) -> [ActualTransaction] {
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

    func mapTransactionRow(_ row: Row) -> ActualTransaction {
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
            reconciled: flexibleBool(row["reconciled"]),
            isParent: flexibleBool(row["is_parent"]),
            isChild: (parentID?.isEmpty == false),
            parentID: parentID
        )
    }
}
