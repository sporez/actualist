import Foundation
import GRDB

enum GroupedTransactionPagePlan: Equatable, Sendable {
    case assembledLiveRows
    case familyLookup

    static func make(limit: Int?, hasQueryFilter: Bool) -> Self {
        if limit == nil && !hasQueryFilter {
            return .assembledLiveRows
        }
        return .familyLookup
    }
}

enum TransactionGroupedOrdering {
    static func transactions(
        _ assembled: [ActualTransaction],
        orderedByGroupIDs groupIDs: [String]
    ) -> [ActualTransaction] {
        var byID: [String: ActualTransaction] = [:]
        byID.reserveCapacity(assembled.count)
        for transaction in assembled {
            guard let id = transaction.id else { continue }
            byID[id] = transaction
        }
        return groupIDs.compactMap { byID[$0] }
    }
}

extension BudgetDatabase {

    func fetchTransactions(accountID: String? = nil, matching query: String? = nil) throws -> [ActualTransaction] {
        try fetchTransactionPage(accountID: accountID, matching: query, limit: nil, offset: 0).transactions
    }

    func fetchTransaction(id: String) throws -> ActualTransaction? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return try queue.read { db in
            guard try tableExists("transactions", db: db) else {
                return nil
            }

            let columns = try columnSet(for: "transactions", db: db)
            let split = transactionSplitQueryExpressions(columns: columns)
            let normalizedDate = normalizedDateExpression(split.qualifiedDate)
            let joins = try transactionReadJoins(db: db, split: split, includeNames: false)
            let familyPredicate: String
            let arguments: [DatabaseValueConvertible]
            if split.hasParentIDColumn {
                familyPredicate = """
                    t.id = ?
                    OR \(split.effectiveParentID) = ?
                    OR t.id = (
                        SELECT parent_id FROM transactions
                        WHERE id = ? AND \(predicateForLiveRows(columns: columns))
                    )
                    """
                arguments = [trimmed, trimmed, trimmed]
            } else {
                familyPredicate = "t.id = ?"
                arguments = [trimmed]
            }

            let sql = """
                SELECT \(transactionReadSelectList(split: split, joins: joins, normalizedDate: normalizedDate))
                FROM transactions t
                \(joins.sql)
                \(split.parentJoin())
                WHERE \(split.liveEffectivePredicate())
                  AND (\(familyPredicate))
                ORDER BY \(split.defaultOrder(normalizedDate: normalizedDate))
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            let assembled = assembleTransactions(from: rows)
            if let match = assembled.first(where: { $0.id == trimmed }) {
                return match
            }
            for parent in assembled {
                if let child = parent.subtransactions.first(where: { $0.id == trimmed }) {
                    return child
                }
            }
            return assembled.first
        }
    }

    func fetchTransactionPage(
        accountID: String? = nil,
        matching query: String? = nil,
        limit: Int? = nil,
        offset: Int = 0,
        splits: TransactionSplitQueryMode? = nil,
        month: String? = nil
    ) throws -> TransactionFetchResult {
        try queue.read { db in
            guard try tableExists("transactions", db: db) else {
                return TransactionFetchResult(transactions: [], reachedEnd: true)
            }

            let columns = try columnSet(for: "transactions", db: db)
            let split = transactionSplitQueryExpressions(columns: columns)
            let normalizedDate = normalizedDateExpression(split.qualifiedDate)
            let joins = try transactionReadJoins(db: db, split: split, includeNames: true)
            let mode = splits ?? ((query?.isEmpty ?? true) ? .grouped : .all)

            var conditions: [String] = [split.liveEffectivePredicate()]
            var arguments: [DatabaseValueConvertible] = []
            if let accountID {
                conditions.append("\(split.qualifiedAccount) = ?")
                arguments.append(accountID)
            }
            if let month {
                guard isYearMonthID(month) else {
                    return TransactionFetchResult(transactions: [], reachedEnd: true)
                }
                conditions.append("\(normalizedMonthExpression(split.qualifiedDate)) = ?")
                arguments.append(month)
            }
            if let query, !query.isEmpty {
                conditions.append(transactionSearchPredicate(split: split, joins: joins))
                let like = "%\(escapeLikePattern(query))%"
                arguments.append(contentsOf: Array(repeating: like, count: 4))
            }

            let rowLimit = limit.map { max(1, $0) }
            let rowOffset = max(0, offset)

            switch mode {
            case .all, .inline, .none:
                return try fetchFlatTransactionPage(
                    db: db,
                    split: split,
                    joins: joins,
                    normalizedDate: normalizedDate,
                    mode: mode,
                    conditions: conditions,
                    arguments: arguments,
                    rowLimit: rowLimit,
                    rowOffset: rowOffset
                )
            case .grouped:
                return try fetchGroupedTransactionPage(
                    db: db,
                    split: split,
                    joins: joins,
                    normalizedDate: normalizedDate,
                    conditions: conditions,
                    arguments: arguments,
                    hasQueryFilter: query?.isEmpty == false,
                    rowLimit: rowLimit,
                    rowOffset: rowOffset
                )
            }
        }
    }

    /// Reviewable uncategorized rows across every month. Actual web's banner
    /// has no date filter; SQL keeps this from loading categorized history.
    func fetchUncategorizedTransactions() throws -> [ActualTransaction] {
        try queue.read { db in
            guard try tableExists("transactions", db: db) else {
                return []
            }

            let columns = try columnSet(for: "transactions", db: db)
            let split = transactionSplitQueryExpressions(columns: columns)
            let normalizedDate = normalizedDateExpression(split.qualifiedDate)
            let joins = try transactionReadJoins(db: db, split: split, includeNames: true)

            var extraJoin = ""
            var conditions: [String] = [split.liveEffectivePredicate()]
            conditions.append("(\(joins.mappedCategory) IS NULL OR \(joins.mappedCategory) = '')")

            if try tableExists("accounts", db: db) {
                extraJoin = "LEFT JOIN accounts src ON src.id = \(split.qualifiedAccount)"
                conditions.append("IFNULL(src.offbudget, 0) = 0")
            }

            if try tableExists("payees", db: db) {
                let payeeColumns = try columnSet(for: "payees", db: db)
                if payeeColumns.contains("transfer_acct"), try tableExists("accounts", db: db) {
                    conditions.append(
                        "(py.transfer_acct IS NULL OR py.transfer_acct = '' OR IFNULL(pax.offbudget, 0) = 1)"
                    )
                }
            }

            let uncategorizedJoins = TransactionReadJoins(
                sql: [joins.sql, extraJoin].filter { !$0.isEmpty }.joined(separator: "\n"),
                mappedPayee: joins.mappedPayee,
                mappedCategory: joins.mappedCategory,
                payeeNameSelect: joins.payeeNameSelect,
                categoryNameSelect: joins.categoryNameSelect
            )
            return try fetchFlatTransactionPage(
                db: db,
                split: split,
                joins: uncategorizedJoins,
                normalizedDate: normalizedDate,
                mode: .inline,
                conditions: conditions,
                arguments: [],
                rowLimit: nil,
                rowOffset: 0
            ).transactions
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
            if transaction.isChild, let parentID = transaction.parentID, !parentID.isEmpty {
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

    func existingImportedIDs(accountID: String) throws -> Set<String> {
        try queue.read { db in
            guard try tableExists("transactions", db: db) else {
                return []
            }
            let columns = try columnSet(for: "transactions", db: db)
            guard let importedIDColumn = ["financial_id", "imported_id"].first(where: columns.contains),
                  let accountColumn = ["acct", "account"].first(where: columns.contains) else {
                return []
            }
            let values = try String.fetchAll(
                db,
                sql: """
                    SELECT \(importedIDColumn)
                    FROM transactions
                    WHERE \(accountColumn) = ?
                      AND \(importedIDColumn) IS NOT NULL
                      AND \(predicateForLiveRows(columns: columns))
                    """,
                arguments: [accountID]
            )
            return Set(values.compactMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return trimmed.isEmpty ? nil : trimmed
            })
        }
    }

    func mapTransactionRow(_ row: Row) -> ActualTransaction {
        let parentID = (row["parent_id"] as String?).flatMap { $0.isEmpty ? nil : $0 }
        let payeeName = (row["payee_name"] as String?).flatMap { $0.isEmpty ? nil : $0 }
        let amount: Int? = row["amount"]
        let isParent = flexibleBool(row["is_parent"])
        let isChild = flexibleBool(row["is_child"])
        return ActualTransaction(
            id: row["id"],
            account: row["account_id"] ?? "",
            date: row["date"] ?? "",
            amount: amount.map { actualAmountToMinorUnits($0) },
            payee: row["payee_id"],
            payeeName: payeeName,
            importedPayee: row["imported_payee"],
            category: isParent ? nil : row["category_id"],
            notes: row["notes"],
            cleared: flexibleBool(row["cleared"]) ? .bool(true) : .bool(false),
            reconciled: flexibleBool(row["reconciled"]),
            isParent: isParent,
            isChild: isChild,
            parentID: isChild ? parentID : nil,
            schedule: row["schedule"],
            error: parseSplitTransactionError(row["error"])
        )
    }
}

private struct TransactionReadJoins {
    let sql: String
    let mappedPayee: String
    let mappedCategory: String
    let payeeNameSelect: String
    let categoryNameSelect: String
}

private extension BudgetDatabase {
    func transactionReadJoins(
        db: Database,
        split: TransactionSplitQueryExpressions,
        includeNames: Bool
    ) throws -> TransactionReadJoins {
        let hasCategoryMapping = try tableExists("category_mapping", db: db)
        let mappedCategory = hasCategoryMapping
            ? "COALESCE(cm.transferId, \(split.qualifiedCategory))"
            : split.qualifiedCategory
        let categoryMappingJoin = hasCategoryMapping
            ? "LEFT JOIN category_mapping cm ON cm.id = \(split.qualifiedCategory)"
            : ""

        let hasPayeeMapping = try tableExists("payee_mapping", db: db)
        let mappedPayee = hasPayeeMapping
            ? "COALESCE(pm.targetId, \(split.qualifiedPayee))"
            : split.qualifiedPayee
        let payeeMappingJoin = hasPayeeMapping
            ? "LEFT JOIN payee_mapping pm ON pm.id = \(split.qualifiedPayee)"
            : ""

        var payeeNameJoin = ""
        var payeeNameSelect = "NULL"
        if includeNames, try tableExists("payees", db: db) {
            let payeeColumns = try columnSet(for: "payees", db: db)
            let hasAccounts = try tableExists("accounts", db: db)
            if hasAccounts, payeeColumns.contains("transfer_acct") {
                payeeNameJoin = "LEFT JOIN payees py ON py.id = \(mappedPayee) LEFT JOIN accounts pax ON pax.id = py.transfer_acct"
                payeeNameSelect = "COALESCE(NULLIF(py.name, ''), pax.name)"
            } else {
                payeeNameJoin = "LEFT JOIN payees py ON py.id = \(mappedPayee)"
                payeeNameSelect = "py.name"
            }
        }

        var categoryNameJoin = ""
        var categoryNameSelect = "NULL"
        if includeNames, try tableExists("categories", db: db) {
            categoryNameJoin = "LEFT JOIN categories cat ON cat.id = \(mappedCategory)"
            categoryNameSelect = "cat.name"
        }

        return TransactionReadJoins(
            sql: [categoryMappingJoin, payeeMappingJoin, payeeNameJoin, categoryNameJoin]
                .filter { !$0.isEmpty }
                .joined(separator: "\n"),
            mappedPayee: mappedPayee,
            mappedCategory: mappedCategory,
            payeeNameSelect: payeeNameSelect,
            categoryNameSelect: categoryNameSelect
        )
    }

    func transactionReadSelectList(
        split: TransactionSplitQueryExpressions,
        joins: TransactionReadJoins,
        normalizedDate: String
    ) -> String {
        return """
            t.id AS id,
            \(split.qualifiedAccount) AS account_id,
            \(normalizedDate) AS date,
            \(split.qualifiedAmount) AS amount,
            \(joins.mappedPayee) AS payee_id,
            \(joins.payeeNameSelect) AS payee_name,
            \(split.qualifiedImportedPayee) AS imported_payee,
            \(split.effectiveCategory(mappedCategory: joins.mappedCategory)) AS category_id,
            \(split.qualifiedNotes) AS notes,
            \(split.qualifiedCleared) AS cleared,
            \(split.qualifiedReconciled) AS reconciled,
            \(split.effectiveParentID) AS parent_id,
            \(split.qualifiedIsParent) AS is_parent,
            \(split.qualifiedIsChild) AS is_child,
            \(split.qualifiedSchedule) AS schedule,
            \(split.qualifiedError) AS error
            """
    }

    func transactionSearchPredicate(split: TransactionSplitQueryExpressions, joins: TransactionReadJoins) -> String {
        """
        (\(joins.payeeNameSelect) LIKE ? ESCAPE '\\'
         OR \(split.qualifiedNotes) LIKE ? ESCAPE '\\'
         OR \(joins.categoryNameSelect) LIKE ? ESCAPE '\\'
         OR CAST(\(split.qualifiedAmount) AS TEXT) LIKE ? ESCAPE '\\')
        """
    }

    func fetchFlatTransactionPage(
        db: Database,
        split: TransactionSplitQueryExpressions,
        joins: TransactionReadJoins,
        normalizedDate: String,
        mode: TransactionSplitQueryMode,
        conditions: [String],
        arguments: [DatabaseValueConvertible],
        rowLimit: Int?,
        rowOffset: Int
    ) throws -> TransactionFetchResult {
        var pageConditions = conditions
        pageConditions.append(split.splitModePredicate(mode))
        var pageArguments = arguments
        var limitClause = ""
        if let rowLimit {
            limitClause = "LIMIT ? OFFSET ?"
            pageArguments.append(rowLimit + 1)
            pageArguments.append(rowOffset)
        }
        let sql = """
            SELECT \(transactionReadSelectList(split: split, joins: joins, normalizedDate: normalizedDate))
            FROM transactions t
            \(joins.sql)
            \(split.parentJoin())
            WHERE \(pageConditions.joined(separator: " AND "))
            ORDER BY \(split.defaultOrder(normalizedDate: normalizedDate))
            \(limitClause)
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(pageArguments))
        if let rowLimit {
            let reachedEnd = rows.count <= rowLimit
            let page = Array(rows.prefix(rowLimit))
            return TransactionFetchResult(
                transactions: page.map(mapTransactionRow),
                reachedEnd: reachedEnd
            )
        }
        return TransactionFetchResult(transactions: rows.map(mapTransactionRow), reachedEnd: true)
    }

    func fetchGroupedTransactionPage(
        db: Database,
        split: TransactionSplitQueryExpressions,
        joins: TransactionReadJoins,
        normalizedDate: String,
        conditions: [String],
        arguments: [DatabaseValueConvertible],
        hasQueryFilter: Bool,
        rowLimit: Int?,
        rowOffset: Int
    ) throws -> TransactionFetchResult {
        if GroupedTransactionPagePlan.make(limit: rowLimit, hasQueryFilter: hasQueryFilter) == .assembledLiveRows {
            return try fetchAssembledGroupedTransactions(
                db: db,
                split: split,
                joins: joins,
                normalizedDate: normalizedDate,
                conditions: conditions,
                arguments: arguments
            )
        }

        let groupIDs: [String]
        let reachedEnd: Bool
        if hasQueryFilter {
            var groupArguments = arguments
            var limitClause = ""
            if let rowLimit {
                limitClause = "LIMIT ? OFFSET ?"
                groupArguments.append(rowLimit + 1)
                groupArguments.append(rowOffset)
            }
            let groupSQL = """
                SELECT g.group_id AS group_id FROM (
                    SELECT DISTINCT IFNULL(\(split.effectiveParentID), t.id) AS group_id
                    FROM transactions t
                    \(joins.sql)
                    \(split.parentJoin())
                    WHERE \(conditions.joined(separator: " AND "))
                ) g
                JOIN transactions t ON t.id = g.group_id
                ORDER BY \(split.defaultOrder(normalizedDate: normalizedDate))
                \(limitClause)
                """
            let fetched = try Row.fetchAll(
                db,
                sql: groupSQL,
                arguments: StatementArguments(groupArguments)
            ).compactMap { $0["group_id"] as String? }
            reachedEnd = rowLimit.map { fetched.count <= $0 } ?? true
            groupIDs = rowLimit.map { Array(fetched.prefix($0)) } ?? fetched
        } else {
            var parentConditions = conditions
            parentConditions.append(split.splitModePredicate(.none))
            var parentArguments = arguments
            var limitClause = ""
            if let rowLimit {
                limitClause = "LIMIT ? OFFSET ?"
                parentArguments.append(rowLimit + 1)
                parentArguments.append(rowOffset)
            }
            let parentSQL = """
                SELECT t.id AS id
                FROM transactions t
                \(joins.sql)
                \(split.parentJoin())
                WHERE \(parentConditions.joined(separator: " AND "))
                ORDER BY \(split.defaultOrder(normalizedDate: normalizedDate))
                \(limitClause)
                """
            let fetched = try Row.fetchAll(
                db,
                sql: parentSQL,
                arguments: StatementArguments(parentArguments)
            ).compactMap { $0["id"] as String? }
            reachedEnd = rowLimit.map { fetched.count <= $0 } ?? true
            groupIDs = rowLimit.map { Array(fetched.prefix($0)) } ?? fetched
        }

        guard !groupIDs.isEmpty else {
            return TransactionFetchResult(transactions: [], reachedEnd: true)
        }

        let placeholders = Array(repeating: "?", count: groupIDs.count).joined(separator: ", ")
        let familySQL = """
            SELECT \(transactionReadSelectList(split: split, joins: joins, normalizedDate: normalizedDate))
            FROM transactions t
            \(joins.sql)
            \(split.parentJoin())
            WHERE \(split.liveEffectivePredicate())
              AND IFNULL(\(split.effectiveParentID), t.id) IN (\(placeholders))
            ORDER BY \(split.defaultOrder(normalizedDate: normalizedDate))
            """
        let rows = try Row.fetchAll(
            db,
            sql: familySQL,
            arguments: StatementArguments(groupIDs.map { $0 as DatabaseValueConvertible })
        )
        let assembled = assembleTransactions(from: rows)
        let ordered = TransactionGroupedOrdering.transactions(assembled, orderedByGroupIDs: groupIDs)
        return TransactionFetchResult(transactions: ordered, reachedEnd: reachedEnd)
    }

    func fetchAssembledGroupedTransactions(
        db: Database,
        split: TransactionSplitQueryExpressions,
        joins: TransactionReadJoins,
        normalizedDate: String,
        conditions: [String],
        arguments: [DatabaseValueConvertible]
    ) throws -> TransactionFetchResult {
        let sql = """
            SELECT \(transactionReadSelectList(split: split, joins: joins, normalizedDate: normalizedDate))
            FROM transactions t
            \(joins.sql)
            \(split.parentJoin())
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY \(split.defaultOrder(normalizedDate: normalizedDate))
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        return TransactionFetchResult(
            transactions: assembleTransactions(from: rows),
            reachedEnd: true
        )
    }

    func isYearMonthID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[0].allSatisfy(\.isNumber),
              parts[1].allSatisfy(\.isNumber),
              let month = Int(parts[1]),
              (1...12).contains(month) else {
            return false
        }
        return true
    }
}
