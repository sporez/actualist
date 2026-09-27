import Foundation
import GRDB

struct RawReportActivityDay: Sendable {
    let dayID: String
    let categoryID: String?
    let isIncome: Bool
    let isTransfer: Bool
    let isInflow: Bool
    let amount: Int
}

extension BudgetDatabase {
    func reportActivityDays(
        from startDay: String,
        through endDay: String,
        db: Database
    ) throws -> [RawReportActivityDay] {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return []
        }

        let transactionColumns = try columnSet(for: "transactions", db: db)
        let accountColumns = try columnSet(for: "accounts", db: db)
        let split = transactionSplitQueryExpressions(columns: transactionColumns)
        let offBudget = column("offbudget", fallback: "0", columns: accountColumns)
        let normalizedDate = normalizedDateExpression(split.qualifiedDate)

        let hasCategoryMapping = try tableExists("category_mapping", db: db)
        let mappedCategory: String
        let categoryMappingJoin: String
        if hasCategoryMapping {
            let mappingColumns = try columnSet(for: "category_mapping", db: db)
            if let transferCategory = ["transferId", "transfer_id"].first(where: mappingColumns.contains) {
                mappedCategory = "COALESCE(cm.\(transferCategory), \(split.qualifiedCategory))"
                categoryMappingJoin = "LEFT JOIN category_mapping cm ON cm.id = \(split.qualifiedCategory)"
            } else {
                mappedCategory = split.qualifiedCategory
                categoryMappingJoin = ""
            }
        } else {
            mappedCategory = split.qualifiedCategory
            categoryMappingJoin = ""
        }

        let hasCategories = try tableExists("categories", db: db)
        let hasCategoryGroups = hasCategories ? try tableExists("category_groups", db: db) : false
        let categoryJoin: String
        let groupJoin: String
        let isIncomeExpression: String
        if hasCategories {
            let categoryColumns = try columnSet(for: "categories", db: db)
            let categoryIncome = column("is_income", fallback: "0", columns: categoryColumns)
            let categoryGroup = column(
                "cat_group",
                fallback: column("group_id", fallback: "NULL", columns: categoryColumns),
                columns: categoryColumns
            )
            categoryJoin = "LEFT JOIN categories c ON c.id = \(mappedCategory)"
            if hasCategoryGroups {
                let groupColumns = try columnSet(for: "category_groups", db: db)
                let groupIncome = column("is_income", fallback: "0", columns: groupColumns)
                groupJoin = "LEFT JOIN category_groups g ON g.id = c.\(categoryGroup)"
                isIncomeExpression = "CASE WHEN COALESCE(c.\(categoryIncome), 0) != 0 OR COALESCE(g.\(groupIncome), 0) != 0 THEN 1 ELSE 0 END"
            } else {
                groupJoin = ""
                isIncomeExpression = "CASE WHEN COALESCE(c.\(categoryIncome), 0) != 0 THEN 1 ELSE 0 END"
            }
        } else {
            categoryJoin = ""
            groupJoin = ""
            isIncomeExpression = "0"
        }

        var transferPredicates: [String] = []
        if let transferredID = ["transferred_id", "transfer_id"].first(where: transactionColumns.contains) {
            transferPredicates.append("(t.\(transferredID) IS NOT NULL AND t.\(transferredID) != '')")
        }

        var payeeJoin = ""
        if try tableExists("payees", db: db),
           let payeeColumn = ["description", "payee"].first(where: transactionColumns.contains) {
            let payeeColumns = try columnSet(for: "payees", db: db)
            if let transferAccount = ["transfer_acct", "transfer_account"].first(where: payeeColumns.contains) {
                if try tableExists("payee_mapping", db: db) {
                    let mappingColumns = try columnSet(for: "payee_mapping", db: db)
                    if let targetID = ["targetId", "target_id"].first(where: mappingColumns.contains) {
                        payeeJoin = """
                            LEFT JOIN payee_mapping pm ON pm.id = t.\(payeeColumn)
                            LEFT JOIN payees py ON py.id = COALESCE(pm.\(targetID), t.\(payeeColumn))
                            """
                    } else {
                        payeeJoin = "LEFT JOIN payees py ON py.id = t.\(payeeColumn)"
                    }
                } else {
                    payeeJoin = "LEFT JOIN payees py ON py.id = t.\(payeeColumn)"
                }
                transferPredicates.append("(py.\(transferAccount) IS NOT NULL AND py.\(transferAccount) != '')")
            }
        }
        let isTransferExpression = transferPredicates.isEmpty
            ? "0"
            : "CASE WHEN \(transferPredicates.joined(separator: " OR ")) THEN 1 ELSE 0 END"
        let isInflowExpression = "CASE WHEN \(split.qualifiedAmount) > 0 THEN 1 ELSE 0 END"

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(normalizedDate) AS day,
                       \(mappedCategory) AS category_id,
                       \(isIncomeExpression) AS is_income,
                       \(isTransferExpression) AS is_transfer,
                       \(isInflowExpression) AS is_inflow,
                       SUM(\(split.qualifiedAmount)) AS amount
                FROM transactions t
                JOIN accounts a ON a.id = \(split.qualifiedAccount)
                \(split.parentJoin())
                \(categoryMappingJoin)
                \(categoryJoin)
                \(groupJoin)
                \(payeeJoin)
                WHERE \(split.liveInlinePredicate())
                  AND \(predicateForLiveRows(columns: accountColumns, tableAlias: "a"))
                  AND COALESCE(a.\(offBudget), 0) = 0
                  AND \(normalizedDate) BETWEEN ? AND ?
                -- Grouping by sign is required before cash-flow classification.
                -- Projected columns also avoid treating a literal 0 as a column index.
                GROUP BY 1, 2, 3, 4, 5
                ORDER BY \(normalizedDate)
                """,
            arguments: [startDay, endDay]
        )

        return rows.compactMap { row in
            guard let dayID = flexibleString(row["day"]) else { return nil }
            let categoryID = (row["category_id"] as String?).flatMap { $0.isEmpty ? nil : $0 }
            return RawReportActivityDay(
                dayID: dayID,
                categoryID: categoryID,
                isIncome: flexibleBool(row["is_income"]),
                isTransfer: flexibleBool(row["is_transfer"]),
                isInflow: flexibleBool(row["is_inflow"]),
                amount: row["amount"] ?? 0
            )
        }
    }

    func reportBudgetedExpenses(month: String, db: Database) throws -> Int {
        let table = try budgetTable(db: db)
        guard try tableExists(table.rawValue, db: db) else { return 0 }

        let budgetColumns = try columnSet(for: table.rawValue, db: db)
        let budgetAmount = column("amount", fallback: "0", columns: budgetColumns)
        let budgetMonth = column("month", fallback: "NULL", columns: budgetColumns)
        let normalizedMonth = normalizedMonthExpression("z.\(budgetMonth)")

        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT SUM(z.\(budgetAmount)) AS amount
                FROM \(quotedIdentifier(table.rawValue)) z
                WHERE \(normalizedMonth) = ?
                """,
            arguments: [month]
        )
        return row?["amount"] ?? 0
    }
}
