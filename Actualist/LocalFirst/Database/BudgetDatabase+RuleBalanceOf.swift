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
        excludingTransactionID: String?
    ) throws -> [String: Int] {
        let literals = formulas.flatMap(RuleFormulaEvaluator.extractBalanceOfLiterals)
        guard !literals.isEmpty else { return [:] }
        let accounts = try fetchAccounts()
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var result: [String: Int] = [:]
        for literal in Set(literals) {
            let resolvedID = byID[literal]?.id ?? accounts.first { $0.name == literal }?.id
            if let resolvedID {
                result[literal] = try runningBalanceBeforeTransaction(
                    accountID: resolvedID,
                    date: date,
                    sortOrder: sortOrder,
                    excludingTransactionID: excludingTransactionID
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
        excludingTransactionID: String?
    ) throws -> Int {
        try queue.read { db in
            guard try tableExists("transactions", db: db) else { return 0 }
            let columns = try columnSet(for: "transactions", db: db)
            let expressions = transactionSplitQueryExpressions(columns: columns)
            let dateValue = Self.balanceOfDateFormatter.string(from: date)
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

    private static let balanceOfDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()
}
