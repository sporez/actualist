import Foundation
import GRDB

extension BudgetDatabase {
    /// Prefetched cent balances for Actual `BALANCE_OF("…")` literals.
    /// Missing accounts resolve to 0. Cutoff matches loot-core
    /// `getRunningBalanceBeforeTransaction`: live inline rows strictly before
    /// the current date, plus same-day rows with a lower sort order.
    func prefetchBalanceOf(
        formulas: [String],
        date: Date,
        sortOrder: Double?,
        excludingTransactionID: String?,
        db: Database,
        // Existing direct callers retain the UTC cutoff unless they carry a
        // more specific transaction-day convention.
        dateTimeZone: TimeZone = ActualDateOnly.utc
    ) throws -> [String: Int] {
        let literals = formulas.flatMap(RuleFormulaEvaluator.extractBalanceOfLiterals)
        guard !literals.isEmpty, try tableExists("accounts", db: db) else { return [:] }
        let columns = try columnSet(for: "accounts", db: db)
        guard columns.contains("id") else { return [:] }
        let name = column("name", fallback: "id", columns: columns)
        let order = columns.contains("sort_order") ? "sort_order, lower(name)" : "lower(name)"
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, \(name) AS name FROM accounts WHERE \(predicateForLiveRows(columns: columns)) ORDER BY \(order)"
        )
        let accounts = rows.compactMap { row -> (id: String, name: String)? in
            guard let id = row["id"] as String? else { return nil }
            return (id, row["name"] as String? ?? "")
        }
        let accountIDs = Set(accounts.map(\.id))
        var result: [String: Int] = [:]
        for literal in Set(literals) {
            let resolvedID = accountIDs.contains(literal)
                ? literal
                : accounts.first(where: { $0.name == literal })?.id
            if let resolvedID {
                result[literal] = try runningBalanceBeforeTransaction(
                    accountID: resolvedID,
                    date: date,
                    sortOrder: sortOrder,
                    excludingTransactionID: excludingTransactionID,
                    db: db,
                    dateTimeZone: dateTimeZone
                )
            } else {
                result[literal] = 0
            }
        }
        return result
    }

    private func runningBalanceBeforeTransaction(
        accountID: String,
        date: Date,
        sortOrder: Double?,
        excludingTransactionID: String?,
        dateTimeZone: TimeZone
    ) throws -> Int {
        try queue.read { db in
            try runningBalanceBeforeTransaction(
                accountID: accountID,
                date: date,
                sortOrder: sortOrder,
                excludingTransactionID: excludingTransactionID,
                db: db,
                dateTimeZone: dateTimeZone
            )
        }
    }

    private func runningBalanceBeforeTransaction(
        accountID: String,
        date: Date,
        sortOrder: Double?,
        excludingTransactionID: String?,
        db: Database,
        dateTimeZone: TimeZone
    ) throws -> Int {
            guard try tableExists("transactions", db: db) else { return 0 }
            let columns = try columnSet(for: "transactions", db: db)
            let expressions = transactionSplitQueryExpressions(columns: columns)
            let dateValue = ActualDateOnly.dayID(from: date, timeZone: dateTimeZone)
            let normalizedDate = normalizedDateExpression(expressions.qualifiedDate)
            var predicates = [
                expressions.liveInlinePredicate(),
                "\(expressions.qualifiedAccount) = ?",
            ]
            var arguments = StatementArguments([accountID])
            if let excludingTransactionID {
                predicates.append("t.id != ?")
                arguments += [excludingTransactionID]
            }
            if expressions.hasSortOrderColumn, let sortOrder {
                predicates.append("""
                    (\(normalizedDate) < ? OR (
                        \(normalizedDate) = ?
                        AND \(expressions.qualifiedSortOrder) < ?
                    ))
                    """)
                arguments += [dateValue, dateValue, sortOrder]
            } else {
                predicates.append("""
                    (\(normalizedDate) < ? OR (
                        \(normalizedDate) = ?
                        AND \(expressions.qualifiedSortOrder) IS NOT NULL
                    ))
                    """)
                arguments += [dateValue, dateValue]
            }
            let sql = """
                SELECT COALESCE(SUM(\(expressions.qualifiedAmount)), 0)
                FROM transactions t
                \(expressions.parentJoin())
                WHERE \(predicates.joined(separator: " AND "))
                """
            return Int(try Int64.fetchOne(db, sql: sql, arguments: arguments) ?? 0)
    }

}
