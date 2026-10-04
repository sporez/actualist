import Foundation
import GRDB

extension BudgetDatabase {
    /// One draft's BALANCE_OF cutoff: its logical day and sort order.
    struct BalanceOfCutoff {
        var date: Date
        var sortOrder: Double?
    }

    /// Prefetched cent balances for Actual `BALANCE_OF("…")` literals, one map
    /// per cutoff (`result[i]` belongs to `cutoffs[i]`). Missing accounts
    /// resolve to 0. The cutoff matches loot-core
    /// `getRunningBalanceBeforeTransaction`: live inline rows on an earlier
    /// day, plus same-day rows whose non-null sort order is lower (any non-null
    /// one when the draft has no sort order or the table has no sort_order
    /// column). Each resolved account is read once; every cutoff is then
    /// resolved in memory. Day strings compare bytewise like SQLite's BINARY
    /// collation, and an Int64 overflow throws as SQLite's SUM does.
    func prefetchBalanceOf(
        formulas: [String],
        cutoffs: [BalanceOfCutoff],
        db: Database,
        dateTimeZone: TimeZone
    ) throws -> [[String: Int]] {
        let literals = Set(formulas.flatMap(RuleFormulaEvaluator.extractBalanceOfLiterals))
        guard !literals.isEmpty, !cutoffs.isEmpty, try tableExists("accounts", db: db) else {
            return cutoffs.map { _ in [:] }
        }
        let columns = try columnSet(for: "accounts", db: db)
        guard columns.contains("id") else { return cutoffs.map { _ in [:] } }
        let name = column("name", fallback: "id", columns: columns)
        let order = columns.contains("sort_order") ? "sort_order, lower(name)" : "lower(name)"
        let accounts = try Row.fetchAll(
            db,
            sql: "SELECT id, \(name) AS name FROM accounts WHERE \(predicateForLiveRows(columns: columns)) ORDER BY \(order)"
        ).compactMap { row -> (id: String, name: String)? in
            guard let id = row["id"] as String? else { return nil }
            return (id, row["name"] as String? ?? "")
        }
        let accountIDs = Set(accounts.map(\.id))
        var resolved: [String: String] = [:]
        for literal in literals {
            resolved[literal] = accountIDs.contains(literal)
                ? literal : accounts.first(where: { $0.name == literal })?.id
        }
        let ledgers = try Dictionary(uniqueKeysWithValues: Set(resolved.values).map {
            ($0, try balanceOfLedger(accountID: $0, db: db))
        })
        return try cutoffs.map { cutoff in
            let day = ActualDateOnly.dayID(from: cutoff.date, timeZone: dateTimeZone)
            var balances: [String: Int] = [:]
            for literal in literals {
                balances[literal] = try resolved[literal].flatMap { ledgers[$0] }?
                    .balance(before: day, sortOrder: cutoff.sortOrder) ?? 0
            }
            return balances
        }
    }

    /// An account's live inline rows ordered by normalized day with prefix sums.
    private func balanceOfLedger(accountID: String, db: Database) throws -> BalanceOfLedger {
        guard try tableExists("transactions", db: db) else {
            return BalanceOfLedger(ordersBySortOrder: false, rows: [])
        }
        let columns = try columnSet(for: "transactions", db: db)
        let expressions = transactionSplitQueryExpressions(columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(normalizedDateExpression(expressions.qualifiedDate)) AS day,
                       \(expressions.qualifiedSortOrder) AS sort_order,
                       \(expressions.qualifiedAmount) AS amount
                FROM transactions t
                \(expressions.parentJoin())
                WHERE \(expressions.liveInlinePredicate()) AND \(expressions.qualifiedAccount) = ?
                """,
            arguments: [accountID]
        )
        return BalanceOfLedger(ordersBySortOrder: expressions.hasSortOrderColumn, rows: rows.compactMap { row in
            guard let day = row["day"] as String? else { return nil }
            let sortOrder: Double?
            switch (row["sort_order"] as DatabaseValue).storage {
            case .null: sortOrder = nil
            case .int64(let value): sortOrder = Double(value)
            case .double(let value): sortOrder = value
            case .string, .blob: sortOrder = .infinity  // Sorts after every number in SQLite.
            }
            return BalanceOfLedger.Row(day: day, sortOrder: sortOrder, amount: row["amount"] as Int64? ?? 0)
        })
    }

}

/// Live rows of one account sorted by day, with running totals so a cutoff is
/// a binary search plus a scan of the cutoff day.
struct BalanceOfLedger {
    struct Row {
        var day: String
        var sortOrder: Double?
        var amount: Int64
    }

    private static let overflow = LocalFirstError.invalidLocalWrite("BALANCE_OF total overflowed")

    private let rows: [Row]
    /// Running totals; nil from the first Int64 overflow on (SQLite's SUM
    /// raises there, so a cutoff that needs such a total must throw).
    private let prefix: [Int64?]
    /// False without a sort_order column: the draft's sort order is ignored.
    private let ordersBySortOrder: Bool

    init(ordersBySortOrder: Bool, rows: [Row]) {
        self.ordersBySortOrder = ordersBySortOrder
        self.rows = rows.sorted { $0.day.utf8.lexicographicallyPrecedes($1.day.utf8) }
        var running: [Int64?] = [0]
        for row in self.rows {
            running.append(running[running.count - 1].flatMap {
                let (sum, overflow) = $0.addingReportingOverflow(row.amount)
                return overflow ? nil : sum
            })
        }
        prefix = running
    }

    func balance(before day: String, sortOrder: Double?) throws -> Int {
        var low = 0, high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].day.utf8.lexicographicallyPrecedes(day.utf8) { low = mid + 1 } else { high = mid }
        }
        guard var total = prefix[low] else { throw Self.overflow }
        var index = low
        while index < rows.count, rows[index].day.utf8.elementsEqual(day.utf8) {
            if let rowOrder = rows[index].sortOrder, (ordersBySortOrder ? sortOrder : nil).map({ rowOrder < $0 }) ?? true {
                let (sum, overflow) = total.addingReportingOverflow(rows[index].amount)
                if overflow { throw Self.overflow }
                total = sum
            }
            index += 1
        }
        return Int(total)
    }
}
