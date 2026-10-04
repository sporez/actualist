import Foundation
import GRDB

extension BudgetDatabase {

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
            let isIncome = try templateCategoryIsIncomeByID(db: db)[trimmedCategoryID] ?? false
            guard BudgetActionEligibility.allows(.directAssignment(isIncome: isIncome), in: table) else {
                throw BudgetModeWriteError.unsupportedAction
            }
            let columns = try requiredColumns(
                table: table.rawValue,
                required: ["month", "category", "amount"],
                db: db
            )
            if try tableExists("categories", db: db),
               try !liveRowExists(table: "categories", rowID: trimmedCategoryID, db: db) {
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

    static let maximumCarryoverMonthSpan = 600

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
            let table = try budgetTable(db: db)
            let isIncome = try templateCategoryIsIncomeByID(db: db)[trimmedCategoryID] ?? false
            guard BudgetActionEligibility.allows(.carryover(isIncome: isIncome), in: table) else {
                throw BudgetModeWriteError.unsupportedAction
            }
            let columns = try requiredColumns(
                table: table.rawValue,
                required: ["month", "category", "carryover"],
                db: db
            )
            try validateBudgetCategoryID(trimmedCategoryID, db: db)
            return try categoryCarryoverMessages(
                categoryIDs: [trimmedCategoryID],
                carryover: carryover,
                startMonthValue: startMonthValue,
                throughMonthValue: throughMonthValue,
                table: table,
                columns: columns,
                db: db,
                builder: &builder
            )
        }
    }

    func allExpenseCategoryCarryoverMessages(
        carryover: Bool,
        startMonth: String,
        throughMonth: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let startMonthValue = try Self.actualMonthValue(startMonth)
        let throughMonthValue = try Self.actualMonthValue(throughMonth)
        guard throughMonthValue >= startMonthValue else {
            throw LocalFirstError.invalidLocalWrite("invalid carryover month range")
        }

        return try queue.read { db in
            let table = try budgetTable(db: db)
            guard BudgetActionEligibility.allows(.carryover(isIncome: false), in: table) else {
                throw BudgetModeWriteError.unsupportedAction
            }
            let columns = try requiredColumns(
                table: table.rawValue,
                required: ["month", "category", "carryover"],
                db: db
            )
            let categoryIDs = try templateCategoryIDsInBudgetOrder(
                db: db,
                includeIncome: false,
                includeHidden: true
            )
            return try categoryCarryoverMessages(
                categoryIDs: categoryIDs,
                carryover: carryover,
                startMonthValue: startMonthValue,
                throughMonthValue: throughMonthValue,
                table: table,
                columns: columns,
                db: db,
                builder: &builder
            )
        }
    }

    private func categoryCarryoverMessages(
        categoryIDs: [String],
        carryover: Bool,
        startMonthValue: Int,
        throughMonthValue: Int,
        table: BudgetTable,
        columns: Set<String>,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        var messages: [ActualSyncDecodedMessage] = []
        // Bound the fan-out: a stray far-future budget row must not turn one
        // carryover toggle into a loop over thousands of months.
        let cappedLastMonthValue = shiftedMonth(startMonthValue, by: Self.maximumCarryoverMonthSpan - 1)
        guard throughMonthValue <= cappedLastMonthValue else {
            throw LocalFirstError.invalidLocalWrite("carryover month range too large")
        }
        let effectiveThroughMonthValue = min(
            cappedLastMonthValue,
            max(
                throughMonthValue,
                try maxActiveBudgetMonth(table: table, columns: columns, db: db)
            )
        )
        let existingRowIDs = try budgetRowIDs(table: table, columns: columns, db: db)
        for categoryID in categoryIDs {
            var monthValue = startMonthValue
            while monthValue <= effectiveThroughMonthValue {
                let rowID = existingRowIDs[monthID(monthValue)]?[categoryID]
                    ?? Self.budgetRowID(monthValue: monthValue, categoryID: categoryID)

                // A peer may need these columns to create the budget row.
                messages.append(
                    try builder.makeMessage(
                        dataset: table.rawValue,
                        row: rowID,
                        column: "month",
                        value: .int(Int64(monthValue))
                    )
                )
                messages.append(
                    try builder.makeMessage(
                        dataset: table.rawValue,
                        row: rowID,
                        column: "category",
                        value: .string(categoryID)
                    )
                )
                messages.append(
                    try builder.makeMessage(
                        dataset: table.rawValue,
                        row: rowID,
                        column: "carryover",
                        value: .bool(carryover)
                    )
                )

                monthValue = nextMonth(after: monthValue)
            }
        }
        return messages
    }

    func templateFromLastMonth(
        categoryID: String,
        monthValue: Int,
        isIncome: Bool,
        isTrackingBudget: Bool = false,
        history: TemplateHistory? = nil,
        db: Database
    ) throws -> Int {
        let previousMonthValue = try BudgetTemplateEngine().sourceMonthValue(
            for: monthValue,
            lookBack: 1
        )
        let previousMonth = monthID(previousMonthValue)
        let previousValues = try categoryValues(through: previousMonth, db: db, history: history)[categoryID]
            ?? BudgetCategoryValue()
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

    func moveMoneyMessages(
        commands: [BudgetMoveMoneyCommand],
        month: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            try moveMoneyMessages(commands: commands, month: month, db: db, builder: &builder)
        }
    }

    /// Reads the live budget rows through `db`, so a Move Money commit built in
    /// its own write transaction starts from the latest assigned amounts.
    func moveMoneyMessages(
        commands: [BudgetMoveMoneyCommand],
        month: String,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard !commands.isEmpty else {
            return []
        }
        let monthValue = try Self.actualMonthValue(month)

        let table = try budgetTable(db: db)
        guard BudgetActionEligibility.allows(.moveMoney, in: table) else {
            throw BudgetModeWriteError.unsupportedAction
        }
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
            guard command.amount <= BudgetMoveMoneyCommand.maximumAmount else {
                throw LocalFirstError.numericValueOutOfRange
            }
            guard command.fromCategoryID != nil || command.toCategoryID != nil else {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }
            if let fromCategoryID = command.fromCategoryID?.trimmingCharacters(in: .whitespacesAndNewlines) {
                try validateBudgetCategoryID(fromCategoryID, db: db)
                budgetedByCategory[fromCategoryID] = try BudgetTemplateEngine.checkedSubtract(
                    budgetedByCategory[fromCategoryID] ?? 0,
                    command.amount
                )
                affectedCategoryIDs.insert(fromCategoryID)
            }
            if let toCategoryID = command.toCategoryID?.trimmingCharacters(in: .whitespacesAndNewlines) {
                try validateBudgetCategoryID(toCategoryID, db: db)
                budgetedByCategory[toCategoryID] = try BudgetTemplateEngine.checkedAdd(
                    budgetedByCategory[toCategoryID] ?? 0,
                    command.amount
                )
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

    func validateBudgetCategoryID(_ categoryID: String, db: Database) throws {
        let trimmed = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
        if try tableExists("categories", db: db),
           try !liveRowExists(table: "categories", rowID: trimmed, db: db) {
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

    private func maxActiveBudgetMonth(
        table: BudgetTable,
        columns: Set<String>,
        db: Database
    ) throws -> Int {
        guard columns.contains("month") else { return 0 }
        let predicate = predicateForLiveRows(columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT month FROM \(quotedIdentifier(table.rawValue)) WHERE \(predicate)"
        )
        return rows.compactMap { row in
            canonicalMonthID(flexibleString(row["month"])).map(monthInt)
        }.max() ?? 0
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
