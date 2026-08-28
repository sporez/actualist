import Foundation
import GRDB

extension BudgetDatabase {

    func createAccountMessages(
        accountID: String,
        name: String,
        offbudget: Bool,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccountID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }
        guard !trimmedName.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account name")
        }

        return try queue.read { db in
            let accountColumns = try requiredColumns(
                table: "accounts",
                required: ["name"],
                db: db
            )
            if try rowExists(table: "accounts", rowID: trimmedAccountID, db: db) {
                throw LocalFirstError.invalidLocalWrite("account already exists")
            }

            var messages: [ActualSyncDecodedMessage] = [
                try builder.makeMessage(
                    dataset: "accounts",
                    row: trimmedAccountID,
                    column: "name",
                    value: .string(trimmedName)
                )
            ]
            if accountColumns.contains("offbudget") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "accounts",
                        row: trimmedAccountID,
                        column: "offbudget",
                        value: .bool(offbudget)
                    )
                )
            }
            if accountColumns.contains("closed") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "accounts",
                        row: trimmedAccountID,
                        column: "closed",
                        value: .bool(false)
                    )
                )
            }
            if accountColumns.contains("tombstone") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "accounts",
                        row: trimmedAccountID,
                        column: "tombstone",
                        value: .bool(false)
                    )
                )
            }
            if accountColumns.contains("sort_order") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "accounts",
                        row: trimmedAccountID,
                        column: "sort_order",
                        value: .int(Int64(nextAccountSortOrder(offbudget: offbudget, db: db)))
                    )
                )
            }

            messages += try transferPayeeMessages(forAccountID: trimmedAccountID, db: db, builder: &builder)
            return messages
        }
    }

    func assignCategoryBudgetMessages(
        categoryID: String,
        budgeted: Int,
        month: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedCategoryID = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCategoryID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
        let monthValue = try Self.actualMonthValue(month)

        return try queue.read { db in
            let table = try budgetTable(db: db)
            let columns = try requiredColumns(
                table: table.rawValue,
                required: ["month", "category", "amount"],
                db: db
            )
            if try tableExists("categories", db: db),
               try !rowExists(table: "categories", rowID: trimmedCategoryID, db: db) {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }

            return try assignCategoryBudgetMessages(
                categoryID: trimmedCategoryID,
                budgeted: budgeted,
                monthValue: monthValue,
                table: table,
                columns: columns,
                db: db,
                builder: &builder
            )
        }
    }

    // Actual applies rollover changes through the existing budget horizon.
    func categoryCarryoverMessages(
        categoryID: String,
        carryover: Bool,
        startMonth: String,
        throughMonth: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedCategoryID = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCategoryID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
        let startMonthValue = try Self.actualMonthValue(startMonth)
        let throughMonthValue = try Self.actualMonthValue(throughMonth)
        guard throughMonthValue >= startMonthValue else {
            throw LocalFirstError.invalidLocalWrite("invalid carryover month range")
        }

        return try queue.read { db in
            let columns = try requiredColumns(
                table: "zero_budgets",
                required: ["month", "category", "carryover"],
                db: db
            )
            try validateBudgetCategoryID(trimmedCategoryID, db: db)

            var messages: [ActualSyncDecodedMessage] = []
            var monthValue = startMonthValue
            while monthValue <= throughMonthValue {
                let existingRowID = try budgetRowID(
                    table: .envelope,
                    monthValue: monthValue,
                    categoryID: trimmedCategoryID,
                    columns: columns,
                    db: db
                )
                let rowID = existingRowID
                    ?? Self.budgetRowID(monthValue: monthValue, categoryID: trimmedCategoryID)

                // A peer may need these columns to create the zero_budgets row.
                messages.append(
                    try builder.makeMessage(
                        dataset: "zero_budgets",
                        row: rowID,
                        column: "month",
                        value: .int(Int64(monthValue))
                    )
                )
                messages.append(
                    try builder.makeMessage(
                        dataset: "zero_budgets",
                        row: rowID,
                        column: "category",
                        value: .string(trimmedCategoryID)
                    )
                )
                messages.append(
                    try builder.makeMessage(
                        dataset: "zero_budgets",
                        row: rowID,
                        column: "carryover",
                        value: .bool(carryover)
                    )
                )

                monthValue = nextMonth(after: monthValue)
            }
            return messages
        }
    }

    private func nextAccountSortOrder(offbudget: Bool, db: Database) throws -> Int {
        let columns = try columnSet(for: "accounts", db: db)
        guard columns.contains("sort_order") else {
            return 16_384
        }
        let offbudgetColumn = column("offbudget", fallback: "0", columns: columns)
        let maxSortOrder = try Int.fetchOne(
            db,
            sql: "SELECT MAX(sort_order) FROM accounts WHERE \(offbudgetColumn) = ?",
            arguments: [offbudget ? 1 : 0]
        )
        return (maxSortOrder ?? 0) + 16_384
    }

    private func transferPayeeMessages(
        forAccountID accountID: String,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard try tableExists("payees", db: db) else {
            return []
        }
        let payeeColumns = try requiredColumns(table: "payees", required: ["name"], db: db)
        let transferColumn = payeeColumns.contains("transfer_acct") ? "transfer_acct" : (
            payeeColumns.contains("transferAccount") ? "transferAccount" : nil
        )
        guard let transferColumn else {
            return []
        }

        let payeeID = UUID().uuidString
        var fields: [(String, LocalFirstSyncValue)] = [
            ("name", .string("")),
            (transferColumn, .string(accountID))
        ]
        if payeeColumns.contains("tombstone") {
            fields.append(("tombstone", .bool(false)))
        }
        if payeeColumns.contains("favorite") {
            fields.append(("favorite", .bool(false)))
        }
        if payeeColumns.contains("learn_categories") {
            fields.append(("learn_categories", .bool(false)))
        }
        if payeeColumns.contains("category") {
            fields.append(("category", .null))
        }

        var messages = try fields.map { field in
            try builder.makeMessage(dataset: "payees", row: payeeID, column: field.0, value: field.1)
        }

        if try tableExists("payee_mapping", db: db) {
            let mappingColumns = try requiredColumns(table: "payee_mapping", required: [], db: db)
            let targetColumn = try firstExistingColumn(
                ["targetId", "target_id"],
                in: mappingColumns,
                table: "payee_mapping"
            )
            messages.append(
                try builder.makeMessage(
                    dataset: "payee_mapping",
                    row: payeeID,
                    column: targetColumn,
                    value: .string(payeeID)
                )
            )
        }
        return messages
    }

    func templateFromLastMonth(
        categoryID: String,
        monthValue: Int,
        isIncome: Bool,
        isTrackingBudget: Bool = false,
        db: Database
    ) throws -> Int {
        let previousMonthValue = try BudgetTemplateEngine().sourceMonthValue(
            for: monthValue,
            lookBack: 1
        )
        let previousMonth = monthID(previousMonthValue)
        let previousValues = try envelopeCategoryValues(through: previousMonth, db: db)[categoryID]
            ?? EnvelopeCategoryValue()
        // Actual: leftover < 0 && !carryover || is_income || tracking && !carryover
        if isIncome {
            return 0
        }
        if isTrackingBudget, !previousValues.carryover {
            return 0
        }
        if previousValues.balance < 0, !previousValues.carryover {
            return 0
        }
        return previousValues.balance
    }

    func templateCategoryIsIncomeByID(db: Database) throws -> [String: Bool] {
        guard try tableExists("categories", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "categories", db: db)
        let isIncome = column("is_income", fallback: "0", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, \(isIncome) AS is_income
                FROM categories
                WHERE \(predicateForLiveRows(columns: columns))
                """
        )
        return Dictionary(
            uniqueKeysWithValues: rows.compactMap { row in
                guard let id = row["id"] as String? else {
                    return nil
                }
                return (id, flexibleBool(row["is_income"]))
            }
        )
    }

    func readCategoryGoalDefsRaw(db: Database) throws -> [String: String] {
        guard try tableExists("categories", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "categories", db: db)
        guard columns.contains("goal_def") else {
            return [:]
        }
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, goal_def FROM categories WHERE goal_def IS NOT NULL AND \(predicateForLiveRows(columns: columns))"
        )
        var result: [String: String] = [:]
        for row in rows {
            guard let id = row["id"] as String?,
                  let json = row["goal_def"] as String?,
                  !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            result[id] = json
        }
        return result
    }

    func templateCategoryNames(db: Database) throws -> [String: String] {
        guard try tableExists("categories", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "categories", db: db)
        let name = column("name", fallback: "id", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, \(name) AS name
                FROM categories
                WHERE \(predicateForLiveRows(columns: columns))
                """
        )
        return Dictionary(
            uniqueKeysWithValues: rows.compactMap { row in
                guard let id = row["id"] as String? else {
                    return nil
                }
                let rawCategoryName: String? = row["name"]
                let categoryName = rawCategoryName?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let label = categoryName.flatMap { $0.isEmpty ? nil : $0 } ?? id
                return (id, label)
            }
        )
    }

    func templateCategoryIDsInCategoryOrder(db: Database) throws -> [String] {
        guard try tableExists("categories", db: db) else {
            return []
        }
        let categoryColumns = try columnSet(for: "categories", db: db)
        var order = [String]()
        if categoryColumns.contains("sort_order") {
            order.append("c.sort_order")
        }
        order.append("c.id")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT c.id AS id
                FROM categories c
                WHERE \(predicateForLiveRows(columns: categoryColumns, tableAlias: "c"))
                ORDER BY \(order.joined(separator: ", "))
                """
        )
        return rows.compactMap { $0["id"] as String? }
    }

    func templateCategoryIDsInBudgetOrder(
        db: Database,
        includeIncome: Bool,
        includeHidden: Bool
    ) throws -> [String] {
        guard try tableExists("categories", db: db) else {
            return []
        }
        let categoryColumns = try columnSet(for: "categories", db: db)
        let groupColumn: String?
        if categoryColumns.contains("cat_group") {
            groupColumn = "cat_group"
        } else if categoryColumns.contains("group_id") {
            groupColumn = "group_id"
        } else {
            groupColumn = nil
        }

        var predicates = [predicateForLiveRows(columns: categoryColumns, tableAlias: "c")]
        if !includeIncome, categoryColumns.contains("is_income") {
            predicates.append("(c.is_income = 0 OR c.is_income IS NULL)")
        }
        if !includeHidden, categoryColumns.contains("hidden") {
            predicates.append("(c.hidden = 0 OR c.hidden IS NULL)")
        }

        let groupsExist = try tableExists("category_groups", db: db)
        let groupColumns = groupsExist ? try columnSet(for: "category_groups", db: db) : []
        var join = ""
        var order: [String] = []
        if groupsExist, let groupColumn {
            if includeHidden {
                join = "LEFT JOIN category_groups g ON g.id = c.\(groupColumn)"
            } else {
                join = "INNER JOIN category_groups g ON g.id = c.\(groupColumn)"
                var visibleParts = [predicateForLiveRows(columns: groupColumns, tableAlias: "g")]
                if groupColumns.contains("hidden") {
                    visibleParts.append("(g.hidden = 0 OR g.hidden IS NULL)")
                }
                predicates.append(visibleParts.joined(separator: " AND "))
            }
            if groupColumns.contains("is_income") {
                order.append("g.is_income")
            }
            if groupColumns.contains("sort_order") {
                order.append("g.sort_order")
            }
            order.append("g.id")
        } else if !includeHidden {
            return []
        }
        if categoryColumns.contains("sort_order") {
            order.append("c.sort_order")
        }
        order.append("c.id")

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT c.id AS id
                FROM categories c
                \(join)
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY \(order.joined(separator: ", "))
                """
        )
        return rows.compactMap { $0["id"] as String? }
    }

    func moveMoneyMessages(
        commands: [BudgetMoveMoneyCommand],
        month: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard !commands.isEmpty else {
            return []
        }
        let monthValue = try Self.actualMonthValue(month)

        return try queue.read { db in
            let table = try budgetTable(db: db)
            let columns = try requiredColumns(
                table: table.rawValue,
                required: ["month", "category", "amount"],
                db: db
            )
            let initialBudgets = try categoryBudgets(month: monthID(monthValue), db: db)
            var budgetedByCategory = initialBudgets.mapValues(\.budgeted)
            var affectedCategoryIDs: Set<String> = []

            for command in commands {
                guard command.amount > 0 else {
                    throw LocalFirstError.invalidLocalWrite("missing amount")
                }
                guard command.fromCategoryID != nil || command.toCategoryID != nil else {
                    throw LocalFirstError.invalidLocalWrite("missing category")
                }
                if let fromCategoryID = command.fromCategoryID?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    try validateBudgetCategoryID(fromCategoryID, db: db)
                    budgetedByCategory[fromCategoryID, default: 0] -= command.amount
                    affectedCategoryIDs.insert(fromCategoryID)
                }
                if let toCategoryID = command.toCategoryID?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    try validateBudgetCategoryID(toCategoryID, db: db)
                    budgetedByCategory[toCategoryID, default: 0] += command.amount
                    affectedCategoryIDs.insert(toCategoryID)
                }
            }

            var messages: [ActualSyncDecodedMessage] = []
            for categoryID in affectedCategoryIDs.sorted() {
                messages.append(contentsOf: try assignCategoryBudgetMessages(
                    categoryID: categoryID,
                    budgeted: budgetedByCategory[categoryID] ?? 0,
                    monthValue: monthValue,
                    table: table,
                    columns: columns,
                    db: db,
                    builder: &builder
                ))
            }
            return messages
        }
    }

    func validateBudgetCategoryID(_ categoryID: String, db: Database) throws {
        let trimmed = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
        if try tableExists("categories", db: db),
           try !rowExists(table: "categories", rowID: trimmed, db: db) {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
    }

    func assignCategoryBudgetMessages(
        categoryID: String,
        budgeted: Int,
        monthValue: Int,
        table: BudgetTable,
        columns: Set<String>,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let existingRowID = try budgetRowID(
            table: table,
            monthValue: monthValue,
            categoryID: categoryID,
            columns: columns,
            db: db
        )
        let rowID = existingRowID ?? Self.budgetRowID(monthValue: monthValue, categoryID: categoryID)
        let dataset = table.rawValue
        var messages: [ActualSyncDecodedMessage] = []
        // The server may not know about budget rows created only in the imported file.
        messages.append(
            try builder.makeMessage(
                dataset: dataset,
                row: rowID,
                column: "month",
                value: .int(Int64(monthValue))
            )
        )
        messages.append(
            try builder.makeMessage(
                dataset: dataset,
                row: rowID,
                column: "category",
                value: .string(categoryID)
            )
        )
        if existingRowID == nil, columns.contains("carryover") {
            messages.append(
                try builder.makeMessage(
                    dataset: dataset,
                    row: rowID,
                    column: "carryover",
                    value: .bool(false)
                )
            )
        }
        messages.append(
            try builder.makeMessage(
                dataset: dataset,
                row: rowID,
                column: "amount",
                value: .int(Int64(budgeted))
            )
        )
        return messages
    }

    func budgetRowID(
        table: BudgetTable,
        monthValue: Int,
        categoryID: String,
        columns: Set<String>,
        db: Database
    ) throws -> String? {
        let monthColumn = column("month", fallback: "NULL", columns: columns)
        let categoryColumn = column("category", fallback: "NULL", columns: columns)
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT \(columns.contains("id") ? "id" : "NULL") AS id
                FROM \(quotedIdentifier(table.rawValue))
                WHERE \(normalizedMonthExpression(monthColumn)) = ? AND \(categoryColumn) = ?
                LIMIT 1
                """,
            arguments: [monthID(monthValue), categoryID]
        )
        if columns.contains("id") {
            return row?["id"] as String?
        }
        return row == nil ? nil : Self.budgetRowID(monthValue: monthValue, categoryID: categoryID)
    }

    static func budgetRowID(monthValue: Int, categoryID: String) -> String {
        "\(monthValue)-\(categoryID)"
    }

    func zeroBudgetKey(from rowID: String) throws -> (monthValue: Int, monthID: String, categoryID: String) {
        guard rowID.count > 7 else {
            throw LocalFirstError.invalidLocalWrite("invalid zero_budgets row")
        }
        let monthEnd = rowID.index(rowID.startIndex, offsetBy: 6)
        guard let monthValue = Int(rowID[..<monthEnd]) else {
            throw LocalFirstError.invalidLocalWrite("invalid zero_budgets month")
        }
        let separator = rowID[monthEnd]
        guard separator == "-" else {
            throw LocalFirstError.invalidLocalWrite("invalid zero_budgets row")
        }
        let categoryStart = rowID.index(after: monthEnd)
        let categoryID = String(rowID[categoryStart...])
        guard !categoryID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
        return (monthValue, monthID(monthValue), categoryID)
    }
}
