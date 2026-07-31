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
            let tombstonePredicate = predicateForLiveRows(columns: columns)
            let order = columns.contains("sort_order") ? "sort_order, lower(name)" : "lower(name)"
            let sql = """
                SELECT \(id) AS id,
                       \(name) AS name,
                       \(offbudget) AS offbudget,
                       \(closed) AS closed,
                       \(bank) AS bank,
                       \(accountSyncSource) AS account_sync_source,
                       \(bankSyncStatus) AS bank_sync_status
                FROM accounts
                WHERE \(tombstonePredicate)
                ORDER BY \(order)
                """

            return try Row.fetchAll(db, sql: sql).map { row in
                let bankID = row["bank"] as String?
                let syncSource = row["account_sync_source"] as String?
                return ActualAccount(
                    id: row["id"] ?? "",
                    name: row["name"] ?? "",
                    offbudget: flexibleBool(row["offbudget"]),
                    closed: flexibleBool(row["closed"]),
                    bankSyncLinked: bankID?.isEmpty == false || syncSource?.isEmpty == false,
                    bankSyncStatus: row["bank_sync_status"]
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
            let sql = """
                SELECT id, name, \(category) AS category, \(transferAccount) AS transfer_acct
                FROM payees
                WHERE \(predicateForLiveRows(columns: columns))
                ORDER BY lower(name)
                """
            return try Row.fetchAll(db, sql: sql).map { row in
                ActualPayee(
                    id: row["id"],
                    name: row["name"] ?? "",
                    category: row["category"],
                    transferAccount: row["transfer_acct"]
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

    func fetchBudgetMonth(month: String) throws -> BudgetMonth {
        try queue.read { db in
            let categoryValues = try envelopeCategoryValues(through: month, db: db)
            let groups = try fetchCategoryGroups(categoryValues: categoryValues, db: db)
            let expenseGroups = groups.filter { !$0.isIncome }
            let incomeGroups = groups.filter { $0.isIncome }
            let totalBudgeted = expenseGroups.reduce(0) { $0 + $1.budgeted }
            let totalSpent = expenseGroups.reduce(0) { $0 + $1.spent }
            let totalBalance = expenseGroups.reduce(0) { $0 + $1.balance }
            let totalIncome = incomeGroups.reduce(0) { $0 + $1.spent }
            // "To Budget" is the running amount of on-budget money not yet assigned to a
            // category. Uncategorized rows are intentionally ignored here: Actual leaves them
            // out of both category balances and To Budget until the user categorizes them.
            let onBudgetBalance = try onBudgetAccountBalance(through: month, db: db)
            let uncategorizedActivity = try uncategorizedOnBudgetActivity(through: month, db: db)
            let toBudget = (onBudgetBalance - uncategorizedActivity) - totalBalance

            return BudgetMonth(
                month: month,
                incomeAvailable: toBudget,
                lastMonthOverspent: 0,
                forNextMonth: 0,
                totalBudgeted: totalBudgeted,
                toBudget: toBudget,
                fromLastMonth: 0,
                totalIncome: totalIncome,
                totalSpent: totalSpent,
                totalBalance: totalBalance,
                categoryGroups: groups
            )
        }
    }

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
            // Alias-qualified column when present, or a bare SQL literal fallback when absent
            // (so a missing column becomes `NULL`/`0`, never an invalid `t.NULL`).
            func expr(_ names: [String], fallback: String) -> String {
                for name in names where columns.contains(name) {
                    return "t.\(name)"
                }
                return fallback
            }
            let account = expr(["acct", "account"], fallback: "NULL")
            let date = expr(["date"], fallback: "NULL")
            let amount = expr(["amount"], fallback: "0")
            // Actual stores the payee id in `description` (the `payee` alias only exists in views).
            let payee = expr(["payee", "description"], fallback: "NULL")
            let category = expr(["category"], fallback: "NULL")
            let notes = expr(["notes"], fallback: "NULL")
            let cleared = expr(["cleared"], fallback: "0")
            let importedPayee = expr(["imported_description", "imported_payee"], fallback: "NULL")
            let parentID = expr(["parent_id"], fallback: "NULL")
            let isParent = expr(["isParent", "is_parent"], fallback: "0")
            let normalizedDate = normalizedDateExpression(date)
            let hasCategoryMapping = try tableExists("category_mapping", db: db)
            let mappedCategory = hasCategoryMapping ? "COALESCE(cm.transferId, \(category))" : category
            let categoryMappingJoin = hasCategoryMapping ? "LEFT JOIN category_mapping cm ON cm.id = \(category)" : ""
            // Payees are resolved through payee_mapping (id -> targetId), like categories through
            // category_mapping. Without it, a remapped/merged payee id fails to resolve to a name.
            let hasPayeeMapping = try tableExists("payee_mapping", db: db)
            let mappedPayee = hasPayeeMapping ? "COALESCE(pm.targetId, \(payee))" : payee
            let payeeMappingJoin = hasPayeeMapping ? "LEFT JOIN payee_mapping pm ON pm.id = \(payee)" : ""
            let hasPayees = try tableExists("payees", db: db)
            let hasAccounts = try tableExists("accounts", db: db)
            let payeeColumns = hasPayees ? try columnSet(for: "payees", db: db) : []
            // Transfer payees have an empty name and a `transfer_acct`; their display name is the
            // linked account's name.
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
            isParent: flexibleBool(row["is_parent"]),
            isChild: (parentID?.isEmpty == false),
            parentID: parentID
        )
    }

    func accountBalances() throws -> [String: Int] {
        try queue.read { db in
            guard try tableExists("transactions", db: db) else {
                return [:]
            }

            let columns = try columnSet(for: "transactions", db: db)
            let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
            let amount = column("amount", fallback: "0", columns: columns)
            let parentPredicate = parentTransactionPredicate(columns: columns)
            let sql = """
                SELECT \(account) AS account_id, SUM(\(amount)) AS balance
                FROM transactions
                WHERE \(predicateForLiveRows(columns: columns)) AND \(parentPredicate)
                GROUP BY \(account)
                """
            let rows = try Row.fetchAll(db, sql: sql)
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let accountID = row["account_id"] as String? else {
                    return nil
                }
                return (accountID, actualAmountToMinorUnits(row["balance"] ?? 0))
            })
        }
    }

    func onBudgetAccountBalance(through month: String, db: Database) throws -> Int {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return 0
        }

        let columns = try columnSet(for: "transactions", db: db)
        let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        let date = column("date", fallback: "NULL", columns: columns)
        let parentID = column("parent_id", fallback: "NULL", columns: columns)
        let isParent = column("isParent", fallback: column("is_parent", fallback: "0", columns: columns), columns: columns)
        let budgetMonth = normalizedMonthExpression("t.\(date)")
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT SUM(t.\(amount)) AS balance
                FROM transactions t
                LEFT JOIN accounts a ON a.id = t.\(account)
                LEFT JOIN transactions p ON p.id = t.\(parentID)
                WHERE \(predicateForLiveRows(columns: columns, tableAlias: "t"))
                  AND (t.\(parentID) IS NULL OR p.tombstone = 0 OR p.tombstone IS NULL)
                  AND (t.\(isParent) = 0 OR t.\(isParent) IS NULL)
                  AND a.offbudget = 0
                  AND \(budgetMonth) <= ?
                """,
            arguments: [month]
        )
        return actualAmountToMinorUnits(row?["balance"] ?? 0)
    }

    func uncategorizedOnBudgetActivity(through month: String, db: Database) throws -> Int {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return 0
        }

        let columns = try columnSet(for: "transactions", db: db)
        let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
        let category = column("category", fallback: "NULL", columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        let date = column("date", fallback: "NULL", columns: columns)
        let parentID = column("parent_id", fallback: "NULL", columns: columns)
        let isParent = column("isParent", fallback: column("is_parent", fallback: "0", columns: columns), columns: columns)
        let budgetMonth = normalizedMonthExpression("t.\(date)")
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT SUM(t.\(amount)) AS amount
                FROM transactions t
                LEFT JOIN accounts a ON a.id = t.\(account)
                LEFT JOIN transactions p ON p.id = t.\(parentID)
                WHERE \(predicateForLiveRows(columns: columns, tableAlias: "t"))
                  AND (t.\(parentID) IS NULL OR p.tombstone = 0 OR p.tombstone IS NULL)
                  AND (t.\(isParent) = 0 OR t.\(isParent) IS NULL)
                  AND (t.\(category) IS NULL OR t.\(category) = '')
                  AND a.offbudget = 0
                  AND \(budgetMonth) <= ?
                """,
            arguments: [month]
        )
        return actualAmountToMinorUnits(row?["amount"] ?? 0)
    }

    func fetchCategoryGroups(
        categoryValues: [String: EnvelopeCategoryValue],
        db: Database
    ) throws -> [BudgetMonthCategoryGroup] {
        guard try tableExists("category_groups", db: db) else {
            return []
        }

        let groupColumns = try columnSet(for: "category_groups", db: db)
        let groupHidden = column("hidden", fallback: "0", columns: groupColumns)
        let groupIncome = column("is_income", fallback: "0", columns: groupColumns)
        let groupOrder = groupColumns.contains("sort_order") ? "sort_order, lower(name)" : "lower(name)"
        let groupRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, \(groupIncome) AS is_income, \(groupHidden) AS hidden
                FROM category_groups
                WHERE \(predicateForLiveRows(columns: groupColumns))
                ORDER BY \(groupOrder)
                """
        )

        return try groupRows.map { groupRow in
            let groupID: String = groupRow["id"] ?? ""
            let categories = try fetchBudgetCategories(groupID: groupID, categoryValues: categoryValues, db: db)
            return BudgetMonthCategoryGroup(
                id: groupID,
                name: groupRow["name"] ?? "",
                isIncome: flexibleBool(groupRow["is_income"]),
                hidden: flexibleBool(groupRow["hidden"]),
                budgeted: categories.reduce(0) { $0 + $1.budgeted },
                spent: categories.reduce(0) { $0 + $1.spent },
                balance: categories.reduce(0) { $0 + $1.balance },
                categories: categories
            )
        }
    }

    func fetchBudgetCategories(
        groupID: String,
        categoryValues: [String: EnvelopeCategoryValue],
        db: Database
    ) throws -> [BudgetMonthCategory] {
        guard try tableExists("categories", db: db) else {
            return []
        }

        let categoryColumns = try columnSet(for: "categories", db: db)
        let groupColumn = column("cat_group", fallback: column("group_id", fallback: "NULL", columns: categoryColumns), columns: categoryColumns)
        let categoryHidden = column("hidden", fallback: "0", columns: categoryColumns)
        let categoryIncome = column("is_income", fallback: "0", columns: categoryColumns)
        let categoryOrder = categoryColumns.contains("sort_order") ? "sort_order, lower(name)" : "lower(name)"
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, \(categoryIncome) AS is_income, \(categoryHidden) AS hidden, \(groupColumn) AS group_id
                FROM categories
                WHERE \(predicateForLiveRows(columns: categoryColumns)) AND \(groupColumn) = ?
                ORDER BY \(categoryOrder)
                """,
            arguments: [groupID]
        )

        return rows.map { row in
            let id: String = row["id"] ?? ""
            let values = categoryValues[id] ?? EnvelopeCategoryValue()
            return BudgetMonthCategory(
                id: id,
                name: row["name"] ?? "",
                isIncome: flexibleBool(row["is_income"]),
                hidden: flexibleBool(row["hidden"]),
                groupID: row["group_id"] ?? groupID,
                budgeted: values.budgeted,
                spent: values.spent,
                balance: values.balance,
                carryover: values.carryover
            )
        }
    }

    func envelopeCategoryValues(through month: String, db: Database) throws -> [String: EnvelopeCategoryValue] {
        let budgetedByMonth = try categoryBudgetsByMonth(db: db)
        let spentByMonth = try categorySpendingByMonth(db: db)
        let targetMonthInt = monthInt(month)
        let earliestMonthInt = Array(Set(budgetedByMonth.keys).union(spentByMonth.keys))
            .compactMap(monthInt)
            .filter { $0 <= targetMonthInt }
            .min() ?? targetMonthInt

        var previousBalanceByCategory: [String: Int] = [:]
        var previousCarryoverByCategory: [String: Bool] = [:]
        var targetValues: [String: EnvelopeCategoryValue] = [:]

        var monthCursor = earliestMonthInt
        while monthCursor <= targetMonthInt {
            let budgetMonth = monthID(monthCursor)
            let budgeted = budgetedByMonth[budgetMonth] ?? [:]
            let spent = spentByMonth[budgetMonth] ?? [:]
            let categoryIDs = Set(budgeted.keys).union(spent.keys).union(previousBalanceByCategory.keys)
            var nextBalanceByCategory: [String: Int] = [:]
            var nextCarryoverByCategory: [String: Bool] = [:]

            for categoryID in categoryIDs {
                let budget = budgeted[categoryID] ?? (budgeted: 0, carryover: false)
                let spentAmount = spent[categoryID] ?? 0
                let previousBalance = previousBalanceByCategory[categoryID] ?? 0
                let previousContribution = previousCarryoverByCategory[categoryID] == true
                    ? previousBalance
                    : max(0, previousBalance)
                let balance = budget.budgeted + spentAmount + previousContribution
                nextBalanceByCategory[categoryID] = balance
                nextCarryoverByCategory[categoryID] = budget.carryover

                if budgetMonth == month {
                    targetValues[categoryID] = EnvelopeCategoryValue(
                        budgeted: budget.budgeted,
                        spent: spentAmount,
                        balance: balance,
                        carryover: budget.carryover
                    )
                }
            }

            previousBalanceByCategory = nextBalanceByCategory
            previousCarryoverByCategory = nextCarryoverByCategory
            monthCursor = nextMonth(after: monthCursor)
        }

        return targetValues
    }

    func categoryBudgets(month: String, db: Database) throws -> [String: (budgeted: Int, carryover: Bool)] {
        guard try tableExists("zero_budgets", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "zero_budgets", db: db)
        let category = column("category", fallback: "NULL", columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        let carryover = column("carryover", fallback: "0", columns: columns)
        let budgetMonth = normalizedMonthExpression("month")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(category) AS category_id, \(amount) AS amount, \(carryover) AS carryover
                FROM zero_budgets
                WHERE \(budgetMonth) = ?
                """,
            arguments: [month]
        )
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let categoryID = row["category_id"] as String? else {
                return nil
            }
            return (
                categoryID,
                (
                    budgeted: actualAmountToMinorUnits(row["amount"] ?? 0),
                    carryover: flexibleBool(row["carryover"])
                )
            )
        })
    }

    func categoryBudgetsByMonth(db: Database) throws -> [String: [String: (budgeted: Int, carryover: Bool)]] {
        guard try tableExists("zero_budgets", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "zero_budgets", db: db)
        let category = column("category", fallback: "NULL", columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        let carryover = column("carryover", fallback: "0", columns: columns)
        let budgetMonth = normalizedMonthExpression("month")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(budgetMonth) AS month, \(category) AS category_id, \(amount) AS amount, \(carryover) AS carryover
                FROM zero_budgets
                WHERE month IS NOT NULL
                """
        )
        return rows.reduce(into: [:]) { result, row in
            guard
                let month = flexibleString(row["month"]),
                let categoryID = row["category_id"] as String?
            else {
                return
            }
            result[month, default: [:]][categoryID] = (
                budgeted: actualAmountToMinorUnits(row["amount"] ?? 0),
                carryover: flexibleBool(row["carryover"])
            )
        }
    }

    func categorySpending(month: String, db: Database) throws -> [String: Int] {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "transactions", db: db)
        let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
        let category = column("category", fallback: "NULL", columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        let date = column("date", fallback: "NULL", columns: columns)
        let parentID = column("parent_id", fallback: "NULL", columns: columns)
        let isParent = column("isParent", fallback: column("is_parent", fallback: "0", columns: columns), columns: columns)
        let categoryMappingJoin = try tableExists("category_mapping", db: db)
            ? "LEFT JOIN category_mapping cm ON cm.id = t.\(category)"
            : ""
        let mappedCategory = try tableExists("category_mapping", db: db)
            ? "COALESCE(cm.transferId, t.\(category))"
            : "t.\(category)"
        let budgetMonth = normalizedMonthExpression("t.\(date)")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(mappedCategory) AS category_id, SUM(t.\(amount)) AS amount
                FROM transactions t
                \(categoryMappingJoin)
                LEFT JOIN accounts a ON a.id = t.\(account)
                LEFT JOIN transactions p ON p.id = t.\(parentID)
                WHERE \(predicateForLiveRows(columns: columns, tableAlias: "t"))
                  AND (t.\(parentID) IS NULL OR p.tombstone = 0 OR p.tombstone IS NULL)
                  AND (t.\(isParent) = 0 OR t.\(isParent) IS NULL)
                  AND t.\(category) IS NOT NULL
                  AND a.offbudget = 0
                  AND \(budgetMonth) = ?
                GROUP BY \(mappedCategory)
                """,
            arguments: [month]
        )
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let categoryID = row["category_id"] as String? else {
                return nil
            }
            return (categoryID, actualAmountToMinorUnits(row["amount"] ?? 0))
        })
    }

    func categorySpendingByMonth(db: Database) throws -> [String: [String: Int]] {
        guard try tableExists("transactions", db: db), try tableExists("accounts", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "transactions", db: db)
        let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
        let category = column("category", fallback: "NULL", columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        let date = column("date", fallback: "NULL", columns: columns)
        let parentID = column("parent_id", fallback: "NULL", columns: columns)
        let isParent = column("isParent", fallback: column("is_parent", fallback: "0", columns: columns), columns: columns)
        let categoryMappingJoin = try tableExists("category_mapping", db: db)
            ? "LEFT JOIN category_mapping cm ON cm.id = t.\(category)"
            : ""
        let mappedCategory = try tableExists("category_mapping", db: db)
            ? "COALESCE(cm.transferId, t.\(category))"
            : "t.\(category)"
        let budgetMonth = normalizedMonthExpression("t.\(date)")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(budgetMonth) AS month, \(mappedCategory) AS category_id, SUM(t.\(amount)) AS amount
                FROM transactions t
                \(categoryMappingJoin)
                LEFT JOIN accounts a ON a.id = t.\(account)
                LEFT JOIN transactions p ON p.id = t.\(parentID)
                WHERE \(predicateForLiveRows(columns: columns, tableAlias: "t"))
                  AND (t.\(parentID) IS NULL OR p.tombstone = 0 OR p.tombstone IS NULL)
                  AND (t.\(isParent) = 0 OR t.\(isParent) IS NULL)
                  AND t.\(category) IS NOT NULL
                  AND a.offbudget = 0
                GROUP BY \(budgetMonth), \(mappedCategory)
                """
        )
        return rows.reduce(into: [:]) { result, row in
            guard
                let month = flexibleString(row["month"]),
                let categoryID = row["category_id"] as String?
            else {
                return
            }
            result[month, default: [:]][categoryID] = actualAmountToMinorUnits(row["amount"] ?? 0)
        }
    }

    func transactionBudgetSource(db: Database) throws -> TransactionBudgetSource {
        if try tableExists("v_transactions_internal_alive", db: db) {
            return TransactionBudgetSource(
                tableExists: true,
                table: "v_transactions_internal_alive",
                account: "account",
                category: "t.category",
                amount: "t.amount",
                month: normalizedMonthExpression("t.date"),
                livePredicate: "1 = 1"
            )
        }

        guard try tableExists("transactions", db: db) else {
            return TransactionBudgetSource(
                tableExists: false,
                table: "transactions",
                account: "acct",
                category: "category",
                amount: "amount",
                month: normalizedMonthExpression("date"),
                livePredicate: "1 = 0"
            )
        }

        let columns = try columnSet(for: "transactions", db: db)
        let account = column("acct", fallback: column("account", fallback: "NULL", columns: columns), columns: columns)
        let category = column("category", fallback: "NULL", columns: columns)
        let amount = column("amount", fallback: "0", columns: columns)
        return TransactionBudgetSource(
            tableExists: true,
            table: "transactions",
            account: account,
            category: "t.\(category)",
            amount: "t.\(amount)",
            month: normalizedMonthExpression("t.date"),
            livePredicate: "\(predicateForLiveRows(columns: columns, tableAlias: "t")) AND \(parentTransactionPredicate(columns: columns, tableAlias: "t"))"
        )
    }
}
