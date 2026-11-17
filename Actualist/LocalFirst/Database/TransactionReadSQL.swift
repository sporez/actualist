import Foundation
import GRDB

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

struct UncategorizedReadContext {
    let split: TransactionSplitQueryExpressions
    let normalizedDate: String
    let joins: TransactionReadJoins
    let conditions: [String]
}

enum TransactionReadSQL {
    static func fetchTransactions(accountID: String? = nil, matching query: String? = nil, in database: isolated BudgetDatabase) throws -> [ActualTransaction] {
        try fetchTransactionPage(accountID: accountID, matching: query, limit: nil, offset: 0, in: database).transactions
    }

    static func fetchTransaction(id: String, in database: isolated BudgetDatabase) throws -> ActualTransaction? {
        try database.queue.read { db in try fetchTransaction(id: id, in: database, db: db) }
    }

    /// One read, so a deleted row is never mistaken for one that hasn't synced yet.
    static func sharedTransactionLookup(id: String, in database: isolated BudgetDatabase) throws -> SharedTransactionLookup {
        try database.queue.read { db in
            if let transaction = try fetchTransaction(id: id, in: database, db: db) {
                guard transaction.isChild, let parentID = transaction.parentID else { return .found(transaction) }
                return try fetchTransaction(id: parentID, in: database, db: db).map(SharedTransactionLookup.found) ?? .deleted
            }
            guard try database.tableExists("transactions", db: db) else { return .missing }
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM transactions WHERE id = ?)",
                arguments: [id]
            ) ?? false
            return exists ? .deleted : .missing
        }
    }

    /// Reads through `db`, so a write transaction can read the live row it is about to change.
    static func fetchTransaction(id: String, in database: isolated BudgetDatabase, db: Database) throws -> ActualTransaction? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        guard try database.tableExists("transactions", db: db) else {
            return nil
        }

        let columns = try database.columnSet(for: "transactions", db: db)
        let split = TransactionSplitQueryExpressions(columns: columns)
        let normalizedDate = database.normalizedDateExpression(split.qualifiedDate)
        let joins = try TransactionReadJoins.resolve(
            split: split,
            transactionColumns: columns,
            includeNames: false,
            in: database,
            db: db
        )
        let familyPredicate: String
        let arguments: [DatabaseValueConvertible]
        if split.hasParentIDColumn {
            familyPredicate = """
                t.id = ?
                OR \(split.effectiveParentID) = ?
                OR t.id = (
                    SELECT parent_id FROM transactions
                    WHERE id = ? AND \(database.predicateForLiveRows(columns: columns))
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

    static func fetchTransactionPage(
        accountID: String? = nil,
        matching query: String? = nil,
        limit: Int? = nil,
        offset: Int = 0,
        splits: TransactionSplitQueryMode? = nil,
        month: String? = nil,
        statusFilter: TransactionStatusFilter = .all,
        in database: isolated BudgetDatabase
    ) throws -> BudgetDatabase.TransactionFetchResult {
        if splits == nil, month == nil {
            let scope = accountID.map(TransactionQueryScope.account) ?? .spending
            let page = try TransactionQuerySQL.fetchTransactionQueryPage(
                scope: scope,
                query: TransactionFeedQuery(status: statusFilter, text: query),
                limit: limit,
                offset: offset,
                in: database
            )
            return BudgetDatabase.TransactionFetchResult(
                transactions: page.transactions,
                reachedEnd: page.reachedEnd,
                nextOffset: page.nextOffset
            )
        }
        return try database.queue.read { db in
            guard try database.tableExists("transactions", db: db) else {
                return BudgetDatabase.TransactionFetchResult(transactions: [], reachedEnd: true, nextOffset: max(0, offset))
            }

            let columns = try database.columnSet(for: "transactions", db: db)
            let split = TransactionSplitQueryExpressions(columns: columns)
            let normalizedDate = database.normalizedDateExpression(split.qualifiedDate)
            var joins = try TransactionReadJoins.resolve(
                split: split,
                transactionColumns: columns,
                includeNames: true,
                in: database,
                db: db
            )
            let mode = splits ?? ((query?.isEmpty ?? true) ? .grouped : .all)

            var conditions: [String] = [split.liveEffectivePredicate()]
            var arguments: [DatabaseValueConvertible] = []
            if let accountID {
                conditions.append("\(split.qualifiedAccount) = ?")
                arguments.append(accountID)
            }
            if let month {
                guard isYearMonthID(month) else {
                    return BudgetDatabase.TransactionFetchResult(transactions: [], reachedEnd: true, nextOffset: max(0, offset))
                }
                conditions.append("\(database.normalizedMonthExpression(split.qualifiedDate)) = ?")
                arguments.append(month)
            }
            if let query, !query.isEmpty {
                conditions.append(transactionSearchPredicate(split: split, joins: joins))
                let like = "%\(escapeLikePattern(query))%"
                arguments.append(contentsOf: Array(repeating: like, count: 4))
            }

            if statusFilter == .uncategorized {
                let context = try uncategorizedReadContext(in: database, db: db)
                joins = context.joins
                conditions.append(contentsOf: context.conditions.dropFirst())
                conditions.append(split.splitModePredicate(.inline))
            } else if let statusPredicate = statusFilterPredicate(statusFilter, split: split) {
                conditions.append(statusPredicate)
            }

            let rowLimit = limit.map { max(1, $0) }
            let rowOffset = max(0, offset)

            switch mode {
            case .all, .inline, .none:
                return try fetchFlatTransactionPage(
                    split: split,
                    joins: joins,
                    normalizedDate: normalizedDate,
                    mode: mode,
                    conditions: conditions,
                    arguments: arguments,
                    rowLimit: rowLimit,
                    rowOffset: rowOffset,
                    db: db
                )
            case .grouped:
                return try fetchGroupedTransactionPage(
                    split: split,
                    joins: joins,
                    normalizedDate: normalizedDate,
                    conditions: conditions,
                    arguments: arguments,
                    selectsMatchedGroups: query?.isEmpty == false || statusFilter != .all,
                    allowsUnfilteredFastPath: statusFilter == .all && query?.isEmpty != false,
                    rowLimit: rowLimit,
                    rowOffset: rowOffset,
                    db: db
                )
            }
        }
    }

    /// Reviewable uncategorized rows across every month. Actual web's banner
    /// has no date filter; SQL keeps this from loading categorized history.
    static func fetchUncategorizedTransactions(in database: isolated BudgetDatabase) throws -> [ActualTransaction] {
        try database.queue.read { db in
            guard try database.tableExists("transactions", db: db) else {
                return []
            }
            let context = try uncategorizedReadContext(in: database, db: db)
            return try fetchFlatTransactionPage(
                split: context.split,
                joins: context.joins,
                normalizedDate: context.normalizedDate,
                mode: .inline,
                conditions: context.conditions,
                arguments: [],
                rowLimit: nil,
                rowOffset: 0,
                db: db
            ).transactions
        }
    }

    /// Count used by the first Budget frame. Full transaction/name/category
    /// models remain lazy until the user opens the Uncategorized sheet.
    static func fetchUncategorizedTransactionCount(in database: isolated BudgetDatabase) throws -> Int {
        try database.queue.read { db in
            guard try database.tableExists("transactions", db: db) else {
                return 0
            }
            let context = try uncategorizedReadContext(in: database, db: db)
            let conditions = context.conditions + [
                context.split.splitModePredicate(.inline),
            ]
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM transactions t
                    \(context.joins.sql)
                    \(context.split.parentJoin())
                    WHERE \(conditions.joined(separator: " AND "))
                    """
            ) ?? 0
        }
    }

    static func escapeLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func assembleTransactions(from rows: [Row]) -> [ActualTransaction] {
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

    static func existingImportedIDs(accountID: String, in database: isolated BudgetDatabase) throws -> Set<String> {
        try database.queue.read { db in try database.existingImportedIDs(accountID: accountID, db: db) }
    }

    static func mapTransactionRow(_ row: Row) -> ActualTransaction {
        let parentID = (row["parent_id"] as String?).flatMap { $0.isEmpty ? nil : $0 }
        let payeeName = (row["payee_name"] as String?).flatMap { $0.isEmpty ? nil : $0 }
        let amount: Int? = row["amount"]
        let isParent = SQLiteValueCoercion.lenientBool(row["is_parent"])
        let isChild = SQLiteValueCoercion.lenientBool(row["is_child"])
        return ActualTransaction(
            id: row["id"],
            account: row["account_id"] ?? "",
            date: row["date"] ?? "",
            amount: amount,
            payee: row["payee_id"],
            payeeName: payeeName,
            importedPayee: row["imported_payee"],
            category: isParent ? nil : row["category_id"],
            notes: row["notes"],
            cleared: SQLiteValueCoercion.lenientBool(row["cleared"]) ? .bool(true) : .bool(false),
            reconciled: SQLiteValueCoercion.lenientBool(row["reconciled"]),
            isParent: isParent,
            isChild: isChild,
            parentID: isChild ? parentID : nil,
            schedule: row["schedule"],
            error: SplitTransactionError.parse(row["error"])
        )
    }

    static func statusFilterPredicate(
        _ filter: TransactionStatusFilter,
        split: TransactionSplitQueryExpressions
    ) -> String? {
        switch filter {
        case .all, .uncategorized:
            nil
        case .uncleared:
            "IFNULL(\(split.qualifiedCleared), 0) = 0 AND IFNULL(\(split.qualifiedReconciled), 0) = 0"
        case .cleared:
            "\(split.qualifiedCleared) = 1 AND IFNULL(\(split.qualifiedReconciled), 0) = 0"
        case .reconciled:
            "IFNULL(\(split.qualifiedReconciled), 0) = 1"
        }
    }

    static func uncategorizedReadContext(in database: isolated BudgetDatabase, db: Database) throws -> UncategorizedReadContext {
        let columns = try database.columnSet(for: "transactions", db: db)
        let split = TransactionSplitQueryExpressions(columns: columns)
        let normalizedDate = database.normalizedDateExpression(split.qualifiedDate)
        let joins = try TransactionReadJoins.resolve(
            split: split,
            transactionColumns: columns,
            includeNames: true,
            in: database,
            db: db
        )

        var extraJoin = ""
        var conditions: [String] = [
            split.liveEffectivePredicate(),
            "(\(joins.liveCategory) IS NULL OR \(joins.liveCategory) = '')",
        ]
        if try database.tableExists("accounts", db: db) {
            extraJoin = "LEFT JOIN accounts src ON src.id = \(split.qualifiedAccount)"
            conditions.append("IFNULL(src.offbudget, 0) = 0")
        }
        if try database.tableExists("payees", db: db) {
            let payeeColumns = try database.columnSet(for: "payees", db: db)
            if payeeColumns.contains("transfer_acct"), try database.tableExists("accounts", db: db) {
                conditions.append(
                    "(py.transfer_acct IS NULL OR py.transfer_acct = '' OR IFNULL(pax.offbudget, 0) = 1)"
                )
            }
        }
        return UncategorizedReadContext(
            split: split,
            normalizedDate: normalizedDate,
            joins: TransactionReadJoins(
                sql: [joins.sql, extraJoin].filter { !$0.isEmpty }.joined(separator: "\n"),
                livePayee: joins.livePayee,
                liveCategory: joins.liveCategory,
                transferIDExpression: joins.transferIDExpression,
                isTransferExpression: joins.isTransferExpression,
                isTransferPayeeExpression: joins.isTransferPayeeExpression,
                payeeNameSelect: joins.payeeNameSelect,
                categoryNameSelect: joins.categoryNameSelect
            ),
            conditions: conditions
        )
    }

    static func transactionReadSelectList(
        split: TransactionSplitQueryExpressions,
        joins: TransactionReadJoins,
        normalizedDate: String
    ) -> String {
        return """
            t.id AS id,
            \(split.qualifiedAccount) AS account_id,
            \(normalizedDate) AS date,
            \(split.qualifiedAmount) AS amount,
            \(joins.livePayee) AS payee_id,
            \(joins.payeeNameSelect) AS payee_name,
            \(split.qualifiedImportedPayee) AS imported_payee,
            \(split.effectiveCategory(category: joins.liveCategory)) AS category_id,
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

    static func transactionSearchPredicate(split: TransactionSplitQueryExpressions, joins: TransactionReadJoins) -> String {
        """
        (\(joins.payeeNameSelect) LIKE ? ESCAPE '\\'
         OR \(split.qualifiedNotes) LIKE ? ESCAPE '\\'
         OR \(joins.categoryNameSelect) LIKE ? ESCAPE '\\'
         OR CAST(\(split.qualifiedAmount) AS TEXT) LIKE ? ESCAPE '\\')
        """
    }

    private static func fetchFlatTransactionPage(
        split: TransactionSplitQueryExpressions,
        joins: TransactionReadJoins,
        normalizedDate: String,
        mode: TransactionSplitQueryMode,
        conditions: [String],
        arguments: [DatabaseValueConvertible],
        rowLimit: Int?,
        rowOffset: Int,
        db: Database
    ) throws -> BudgetDatabase.TransactionFetchResult {
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
        let reachedEnd = rowLimit.map { rows.count <= $0 } ?? true
        let page = rowLimit.map { Array(rows.prefix($0)) } ?? rows
        let mapped = page.map(mapTransactionRow)
        let transactions = mode == .all
            ? try transactionsByAttachingSplitFamilies(
                mapped,
                split: split,
                joins: joins,
                normalizedDate: normalizedDate,
                db: db
            )
            : mapped
        return BudgetDatabase.TransactionFetchResult(
            transactions: transactions,
            reachedEnd: reachedEnd,
            nextOffset: rowOffset + page.count
        )
    }

    private static func fetchGroupedTransactionPage(
        split: TransactionSplitQueryExpressions,
        joins: TransactionReadJoins,
        normalizedDate: String,
        conditions: [String],
        arguments: [DatabaseValueConvertible],
        selectsMatchedGroups: Bool,
        allowsUnfilteredFastPath: Bool,
        rowLimit: Int?,
        rowOffset: Int,
        db: Database
    ) throws -> BudgetDatabase.TransactionFetchResult {
        if rowLimit == nil && allowsUnfilteredFastPath {
            return try fetchAssembledGroupedTransactions(
                split: split,
                joins: joins,
                normalizedDate: normalizedDate,
                conditions: conditions,
                arguments: arguments,
                db: db
            )
        }

        let groupIDs: [String]
        let reachedEnd: Bool
        if selectsMatchedGroups {
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
            return BudgetDatabase.TransactionFetchResult(transactions: [], reachedEnd: true, nextOffset: rowOffset)
        }

        let assembled = try assembledTransactions(
            forGroupIDs: groupIDs,
            split: split,
            joins: joins,
            normalizedDate: normalizedDate,
            db: db
        )
        let ordered = TransactionGroupedOrdering.transactions(assembled, orderedByGroupIDs: groupIDs)
        return BudgetDatabase.TransactionFetchResult(
            transactions: ordered,
            reachedEnd: reachedEnd,
            nextOffset: rowOffset + groupIDs.count
        )
    }

    /// Nested children on parent rows for payee projection. Does not add or
    /// remove page rows, so `.all` search match sets and pagination stay intact.
    static func transactionsByAttachingSplitFamilies(
        _ transactions: [ActualTransaction],
        split: TransactionSplitQueryExpressions,
        joins: TransactionReadJoins,
        normalizedDate: String,
        db: Database
    ) throws -> [ActualTransaction] {
        let parentIDs = transactions.compactMap { transaction -> String? in
            guard transaction.isParent else { return nil }
            return transaction.id
        }
        guard !parentIDs.isEmpty else {
            return transactions
        }
        let childrenByParentID = Dictionary(
            uniqueKeysWithValues: try assembledTransactions(
                forGroupIDs: parentIDs,
                split: split,
                joins: joins,
                normalizedDate: normalizedDate,
                db: db
            ).compactMap { parent -> (String, [ActualTransaction])? in
                guard let id = parent.id else { return nil }
                return (id, parent.subtransactions)
            }
        )
        return transactions.map { transaction in
            guard let id = transaction.id, let children = childrenByParentID[id] else {
                return transaction
            }
            return transaction.replacingSubtransactions(children)
        }
    }

    static func assembledTransactions(
        forGroupIDs groupIDs: [String],
        split: TransactionSplitQueryExpressions,
        joins: TransactionReadJoins,
        normalizedDate: String,
        db: Database
    ) throws -> [ActualTransaction] {
        guard !groupIDs.isEmpty else {
            return []
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
        return assembleTransactions(from: rows)
    }

    private static func fetchAssembledGroupedTransactions(
        split: TransactionSplitQueryExpressions,
        joins: TransactionReadJoins,
        normalizedDate: String,
        conditions: [String],
        arguments: [DatabaseValueConvertible],
        db: Database
    ) throws -> BudgetDatabase.TransactionFetchResult {
        let sql = """
            SELECT \(transactionReadSelectList(split: split, joins: joins, normalizedDate: normalizedDate))
            FROM transactions t
            \(joins.sql)
            \(split.parentJoin())
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY \(split.defaultOrder(normalizedDate: normalizedDate))
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        let transactions = assembleTransactions(from: rows)
        return BudgetDatabase.TransactionFetchResult(
            transactions: transactions,
            reachedEnd: true,
            nextOffset: transactions.count
        )
    }

    private static func isYearMonthID(_ value: String) -> Bool {
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
