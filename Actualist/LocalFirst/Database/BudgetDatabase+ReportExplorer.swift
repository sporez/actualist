import Foundation
import GRDB

private struct RawReportExplorerAmount: Sendable {
    let dayID: String
    let amount: Int
}

private struct RawReportExplorerActivity: Sendable {
    let dayID: String
    let isTransfer: Bool
    let amount: Int
}

extension BudgetDatabase {
    func fetchReportExplorer(query: ReportExplorerQuery) throws -> ReportExplorerSnapshot {
        guard query.hasValidRange else { throw ReportExplorerError.invalidRange }

        switch query.metric {
        case .netWorth:
            let rows = try queue.read { db in
                try reportExplorerBalanceChanges(through: query.endDay, db: db)
            }
            return try buildNetWorthExplorer(query: query, rows: rows)
        case .cashFlow, .spending:
            let rows = try queue.read { db in
                try reportExplorerActivity(
                    from: query.startDay,
                    through: query.endDay,
                    db: db
                )
            }
            return try buildActivityExplorer(query: query, rows: rows)
        }
    }

    private func reportExplorerBalanceChanges(
        through endDay: String,
        db: Database
    ) throws -> [RawReportExplorerAmount] {
        guard try tableExists("transactions", db: db),
              try tableExists("accounts", db: db) else {
            return []
        }

        let transactionColumns = try columnSet(for: "transactions", db: db)
        let accountColumns = try columnSet(for: "accounts", db: db)
        let split = transactionSplitQueryExpressions(columns: transactionColumns)
        let normalizedDate = normalizedDateExpression(split.qualifiedDate)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(normalizedDate) AS day,
                       SUM(\(split.qualifiedAmount)) AS amount
                FROM transactions t
                JOIN accounts a ON a.id = \(split.qualifiedAccount)
                \(split.parentJoin())
                WHERE \(split.liveInlinePredicate())
                  AND \(predicateForLiveRows(columns: accountColumns, tableAlias: "a"))
                  AND \(normalizedDate) <= ?
                GROUP BY \(normalizedDate)
                ORDER BY \(normalizedDate)
                """,
            arguments: [endDay]
        )
        return rows.compactMap { row in
            guard let dayID = flexibleString(row["day"]) else { return nil }
            return RawReportExplorerAmount(dayID: dayID, amount: row["amount"] ?? 0)
        }
    }

    private func reportExplorerActivity(
        from startDay: String,
        through endDay: String,
        db: Database
    ) throws -> [RawReportExplorerActivity] {
        guard try tableExists("transactions", db: db),
              try tableExists("accounts", db: db) else {
            return []
        }

        let transactionColumns = try columnSet(for: "transactions", db: db)
        let accountColumns = try columnSet(for: "accounts", db: db)
        let split = transactionSplitQueryExpressions(columns: transactionColumns)
        let normalizedDate = normalizedDateExpression(split.qualifiedDate)
        let offBudget = column("offbudget", fallback: "0", columns: accountColumns)
        let transfer = try reportExplorerTransferProjection(
            transactionColumns: transactionColumns,
            db: db
        )
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(normalizedDate) AS day,
                       \(transfer.expression) AS is_transfer,
                       SUM(\(split.qualifiedAmount)) AS amount
                FROM transactions t
                JOIN accounts a ON a.id = \(split.qualifiedAccount)
                \(split.parentJoin())
                \(transfer.joins)
                WHERE \(split.liveInlinePredicate())
                  AND \(predicateForLiveRows(columns: accountColumns, tableAlias: "a"))
                  AND COALESCE(a.\(offBudget), 0) = 0
                  AND \(normalizedDate) BETWEEN ? AND ?
                GROUP BY 1, 2
                ORDER BY \(normalizedDate)
                """,
            arguments: [startDay, endDay]
        )
        return rows.compactMap { row in
            guard let dayID = flexibleString(row["day"]) else { return nil }
            return RawReportExplorerActivity(
                dayID: dayID,
                isTransfer: flexibleBool(row["is_transfer"]),
                amount: row["amount"] ?? 0
            )
        }
    }

    private func reportExplorerTransferProjection(
        transactionColumns: Set<String>,
        db: Database
    ) throws -> (joins: String, expression: String) {
        var predicates: [String] = []
        if let transferredID = ["transferred_id", "transfer_id"].first(where: transactionColumns.contains) {
            predicates.append("(t.\(transferredID) IS NOT NULL AND t.\(transferredID) != '')")
        }

        var joins = ""
        if try tableExists("payees", db: db),
           let payeeColumn = ["description", "payee"].first(where: transactionColumns.contains) {
            let payeeColumns = try columnSet(for: "payees", db: db)
            if let transferAccount = ["transfer_acct", "transfer_account"].first(where: payeeColumns.contains) {
                if try tableExists("payee_mapping", db: db) {
                    let mappingColumns = try columnSet(for: "payee_mapping", db: db)
                    if let targetID = ["targetId", "target_id"].first(where: mappingColumns.contains) {
                        joins = """
                            LEFT JOIN payee_mapping pm ON pm.id = t.\(payeeColumn)
                            LEFT JOIN payees py ON py.id = COALESCE(pm.\(targetID), t.\(payeeColumn))
                            """
                    } else {
                        joins = "LEFT JOIN payees py ON py.id = t.\(payeeColumn)"
                    }
                } else {
                    joins = "LEFT JOIN payees py ON py.id = t.\(payeeColumn)"
                }
                predicates.append("(py.\(transferAccount) IS NOT NULL AND py.\(transferAccount) != '')")
            }
        }

        let expression = predicates.isEmpty
            ? "0"
            : "CASE WHEN \(predicates.joined(separator: " OR ")) THEN 1 ELSE 0 END"
        return (joins, expression)
    }

    private func buildNetWorthExplorer(
        query: ReportExplorerQuery,
        rows: [RawReportExplorerAmount]
    ) throws -> ReportExplorerSnapshot {
        let openingBalance = try explorerSum(rows.lazy.filter { $0.dayID < query.startDay }.map(\.amount))
        let changesByDay = try Dictionary(grouping: rows.filter { $0.dayID >= query.startDay }, by: \.dayID)
            .mapValues { try explorerSum($0.map(\.amount)) }
        var balance = openingBalance
        var points: [ReportExplorerPoint] = []
        for period in query.periods {
            for dayID in ReportCalendar.dayIDs(from: period.startDay, through: period.endDay) {
                balance = try explorerAdd(balance, changesByDay[dayID] ?? 0)
            }
            points.append(ReportExplorerPoint(
                period: period,
                income: 0,
                expenses: 0,
                net: 0,
                endingBalance: balance
            ))
        }
        return ReportExplorerSnapshot(
            query: query,
            points: points,
            totals: ReportExplorerTotals(
                income: 0,
                expenses: 0,
                net: 0,
                endingBalance: balance,
                balanceChange: try explorerSubtract(balance, openingBalance)
            ),
            hasData: !rows.isEmpty
        )
    }

    private func buildActivityExplorer(
        query: ReportExplorerQuery,
        rows: [RawReportExplorerActivity]
    ) throws -> ReportExplorerSnapshot {
        let rowsByDay = Dictionary(grouping: rows, by: \.dayID)
        var points: [ReportExplorerPoint] = []
        for period in query.periods {
            var income = 0
            var expenses = 0
            for dayID in ReportCalendar.dayIDs(from: period.startDay, through: period.endDay) {
                for row in rowsByDay[dayID] ?? [] where !row.isTransfer {
                    if row.amount > 0 {
                        income = try explorerAdd(income, row.amount)
                    } else if row.amount < 0 {
                        expenses = try explorerSubtract(expenses, row.amount)
                    }
                }
            }
            points.append(ReportExplorerPoint(
                period: period,
                income: income,
                expenses: expenses,
                net: try explorerSubtract(income, expenses),
                endingBalance: 0
            ))
        }
        let income = try explorerSum(points.map(\.income))
        let expenses = try explorerSum(points.map(\.expenses))
        return ReportExplorerSnapshot(
            query: query,
            points: points,
            totals: ReportExplorerTotals(
                income: income,
                expenses: expenses,
                net: try explorerSubtract(income, expenses),
                endingBalance: 0,
                balanceChange: 0
            ),
            hasData: !rows.isEmpty
        )
    }
}

private func explorerAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow else { throw LocalFirstError.numericValueOutOfRange }
    return result.partialValue
}

private func explorerSubtract(_ lhs: Int, _ rhs: Int) throws -> Int {
    let result = lhs.subtractingReportingOverflow(rhs)
    guard !result.overflow else { throw LocalFirstError.numericValueOutOfRange }
    return result.partialValue
}

private func explorerSum<S: Sequence>(_ values: S) throws -> Int where S.Element == Int {
    var total = 0
    for value in values {
        total = try explorerAdd(total, value)
    }
    return total
}
