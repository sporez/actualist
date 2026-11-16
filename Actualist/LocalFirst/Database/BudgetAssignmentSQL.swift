import Foundation
import GRDB

enum BudgetAssignmentSQL {
    static func assignCategoryBudgetMessages(
        categoryID: String,
        budgeted: Int,
        month: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedCategoryID = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCategoryID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
        let monthValue = try BudgetDatabase.actualMonthValue(month)

        return try database.queue.read { db in
            let table = try database.budgetTable(db: db)
            let isIncome = try TemplateCategorySQL.templateCategoryIsIncomeByID(in: database, db: db)[trimmedCategoryID] ?? false
            guard BudgetActionEligibility.allows(.directAssignment(isIncome: isIncome), in: table) else {
                throw BudgetModeWriteError.unsupportedAction
            }
            let columns = try database.requiredColumns(
                table: table.rawValue,
                required: ["month", "category", "amount"],
                db: db
            )
            if try database.tableExists("categories", db: db),
               try !database.liveRowExists(table: "categories", rowID: trimmedCategoryID, db: db) {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }

            return try BudgetRowSQL.assignCategoryBudgetMessages(
                categoryID: trimmedCategoryID,
                budgeted: budgeted,
                monthValue: monthValue,
                table: table,
                columns: columns,
                builder: &builder,
                in: database,
                db: db
            )
        }
    }

    private static let maximumCarryoverMonthSpan = 600

    private static let toBudgetRowCategoryID = "to-budget"

    // Actual applies rollover changes through the existing budget horizon.
    static func categoryCarryoverMessages(
        categoryID: String,
        carryover: Bool,
        startMonth: String,
        throughMonth: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedCategoryID = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCategoryID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
        let startMonthValue = try BudgetDatabase.actualMonthValue(startMonth)
        let throughMonthValue = try BudgetDatabase.actualMonthValue(throughMonth)
        guard throughMonthValue >= startMonthValue else {
            throw LocalFirstError.refusedChange("That rollover month range is not valid.")
        }

        return try database.queue.read { db in
            let table = try database.budgetTable(db: db)
            let isIncome = try TemplateCategorySQL.templateCategoryIsIncomeByID(in: database, db: db)[trimmedCategoryID] ?? false
            guard BudgetActionEligibility.allows(.carryover(isIncome: isIncome), in: table) else {
                throw BudgetModeWriteError.unsupportedAction
            }
            let columns = try database.requiredColumns(
                table: table.rawValue,
                required: ["month", "category", "carryover"],
                db: db
            )
            try validateBudgetCategoryID(trimmedCategoryID, in: database, db: db)
            return try categoryCarryoverMessages(
                categoryIDs: [trimmedCategoryID],
                carryover: carryover,
                startMonthValue: startMonthValue,
                throughMonthValue: throughMonthValue,
                table: table,
                columns: columns,
                builder: &builder,
                in: database,
                db: db
            )
        }
    }

    static func allExpenseCategoryCarryoverMessages(
        carryover: Bool,
        startMonth: String,
        throughMonth: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let startMonthValue = try BudgetDatabase.actualMonthValue(startMonth)
        let throughMonthValue = try BudgetDatabase.actualMonthValue(throughMonth)
        guard throughMonthValue >= startMonthValue else {
            throw LocalFirstError.refusedChange("That rollover month range is not valid.")
        }

        return try database.queue.read { db in
            let table = try database.budgetTable(db: db)
            guard BudgetActionEligibility.allows(.carryover(isIncome: false), in: table) else {
                throw BudgetModeWriteError.unsupportedAction
            }
            let columns = try database.requiredColumns(
                table: table.rawValue,
                required: ["month", "category", "carryover"],
                db: db
            )
            let categoryIDs = try TemplateCategorySQL.templateCategoryIDsInBudgetOrder(
                includeIncome: false,
                includeHidden: true,
                in: database,
                db: db
            )
            return try categoryCarryoverMessages(
                categoryIDs: categoryIDs,
                carryover: carryover,
                startMonthValue: startMonthValue,
                throughMonthValue: throughMonthValue,
                table: table,
                columns: columns,
                builder: &builder,
                in: database,
                db: db
            )
        }
    }

    private static func categoryCarryoverMessages(
        categoryIDs: [String],
        carryover: Bool,
        startMonthValue: Int,
        throughMonthValue: Int,
        table: BudgetTable,
        columns: Set<String>,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        var messages: [ActualSyncDecodedMessage] = []
        // Bound the fan-out: a stray far-future budget row must not turn one
        // carryover toggle into a loop over thousands of months.
        let cappedLastMonthValue = YearMonth.shiftedUnchecked(packed: startMonthValue, by: Self.maximumCarryoverMonthSpan - 1)
        guard throughMonthValue <= cappedLastMonthValue else {
            throw LocalFirstError.refusedChange("That rollover month range is too large.")
        }
        let effectiveThroughMonthValue = min(
            cappedLastMonthValue,
            max(throughMonthValue, try lastExistingBudgetMonth(in: database, db: db))
        )
        let existingRowIDs = try BudgetRowSQL.budgetRowIDs(table: table, columns: columns, in: database, db: db)
        for categoryID in categoryIDs {
            var monthValue = startMonthValue
            while monthValue <= effectiveThroughMonthValue {
                let rowID = existingRowIDs[YearMonth.id(packed: monthValue)]?[categoryID]
                    ?? BudgetRowSQL.budgetRowID(monthValue: monthValue, categoryID: categoryID)

                // Actual writes the identity cells only when it inserts the row, and
                // its carryover insert stores the month as text.
                if existingRowIDs[YearMonth.id(packed: monthValue)]?[categoryID] == nil {
                    messages += try BudgetRowSQL.budgetRowIdentityMessages(
                        table: table, rowID: rowID, monthValue: monthValue,
                        categoryID: categoryID, monthAsText: true, builder: &builder
                    )
                }
                messages.append(
                    try builder.makeMessage(
                        dataset: table.rawValue,
                        row: rowID,
                        column: "carryover",
                        value: .bool(carryover)
                    )
                )

                monthValue = YearMonth.nextUnchecked(packed: monthValue)
            }
        }
        return messages
    }

    static func moveMoneyMessages(
        commands: [BudgetMoveMoneyCommand],
        month: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        try database.queue.read { db in
            try moveMoneyMessages(commands: commands, month: month, builder: &builder, in: database, db: db)
        }
    }

    /// The commands a move commits: covers and moves from To Budget limited to what their source has
    /// left in `month` (a category's available balance, or To Budget), each leg seeing the legs before it.
    /// Plain moves pass through unchanged. A cover with nothing to move is dropped.
    static func resolvedMoveMoneyCommands(
        _ commands: [BudgetMoveMoneyCommand],
        month: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [BudgetMoveMoneyCommand] {
        guard commands.contains(where: { $0.kind != .move }) else {
            return commands
        }
        let budgetMonth = try BudgetMonthSQL.fetchBudgetMonth(month: month, in: database, db: db)
        var remaining: [String?: Int] = [nil: budgetMonth.toBudget]
        for category in budgetMonth.categoryGroups.flatMap(\.categories) {
            remaining[category.id] = category.balance
        }
        var resolved: [BudgetMoveMoneyCommand] = []
        for command in commands {
            guard command.kind != .move else {
                resolved.append(command)
                continue
            }
            guard let capped = command.limited(toSourceAvailable: remaining[command.fromCategoryID] ?? 0) else {
                continue
            }
            remaining[command.fromCategoryID] = try BudgetTemplateEngine.checkedSubtract(
                remaining[command.fromCategoryID] ?? 0,
                capped.amount
            )
            resolved.append(capped)
        }
        return resolved
    }

    /// Reads the live budget rows through `db`, so a Move Money commit built in
    /// its own write transaction starts from the latest assigned amounts.
    static func moveMoneyMessages(
        commands: [BudgetMoveMoneyCommand],
        month: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        guard !commands.isEmpty else {
            return []
        }
        let monthValue = try BudgetDatabase.actualMonthValue(month)

        let table = try database.budgetTable(db: db)
        guard BudgetActionEligibility.allows(.moveMoney, in: table) else {
            throw BudgetModeWriteError.unsupportedAction
        }
        let columns = try database.requiredColumns(
            table: table.rawValue,
            required: ["month", "category", "amount"],
            db: db
        )
        let initialBudgets = try BudgetCategoryValueSQL.categoryBudgets(month: YearMonth.id(packed: monthValue), in: database, db: db)
        var budgetedByCategory = initialBudgets.mapValues(\.budgeted)
        var affectedCategoryIDs: Set<String> = []

        for command in commands {
            // A transfer-available limited to nothing still writes the destination's row, as Actual does.
            guard command.amount > 0 || (command.kind == .transferAvailable && command.amount == 0) else {
                throw LocalFirstError.invalidLocalWrite("missing amount")
            }
            guard command.amount <= BudgetMoveMoneyCommand.maximumAmount else {
                throw LocalFirstError.numericValueOutOfRange
            }
            guard command.fromCategoryID != nil || command.toCategoryID != nil else {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }
            if let fromCategoryID = command.fromCategoryID?.trimmingCharacters(in: .whitespacesAndNewlines) {
                try validateBudgetCategoryID(fromCategoryID, in: database, db: db)
                budgetedByCategory[fromCategoryID] = try BudgetTemplateEngine.checkedSubtract(
                    budgetedByCategory[fromCategoryID] ?? 0,
                    command.amount
                )
                affectedCategoryIDs.insert(fromCategoryID)
            }
            if let toCategoryID = command.toCategoryID?.trimmingCharacters(in: .whitespacesAndNewlines) {
                try validateBudgetCategoryID(toCategoryID, in: database, db: db)
                budgetedByCategory[toCategoryID] = try BudgetTemplateEngine.checkedAdd(
                    budgetedByCategory[toCategoryID] ?? 0,
                    command.amount
                )
                affectedCategoryIDs.insert(toCategoryID)
            }
        }

        var messages: [ActualSyncDecodedMessage] = []
        // Actual's transfer-category from To Budget stores the move under a `to-budget` row. Its handler
        // reads that row's amount from a sheet cell that never exists, so each move writes the negated amount.
        if let toBudgetLeg = commands.last(where: { $0.fromCategoryID == nil && $0.kind == .move }) {
            messages.append(contentsOf: try BudgetRowSQL.assignCategoryBudgetMessages(
                categoryID: Self.toBudgetRowCategoryID,
                budgeted: -toBudgetLeg.amount,
                monthValue: monthValue,
                table: table,
                columns: columns,
                builder: &builder,
                in: database,
                db: db
            ))
        }
        for categoryID in affectedCategoryIDs.sorted() {
            messages.append(contentsOf: try BudgetRowSQL.assignCategoryBudgetMessages(
                categoryID: categoryID,
                budgeted: budgetedByCategory[categoryID] ?? 0,
                monthValue: monthValue,
                table: table,
                columns: columns,
                builder: &builder,
                in: database,
                db: db
            ))
        }
        return messages
    }

    private static func validateBudgetCategoryID(_ categoryID: String, in database: isolated BudgetDatabase, db: Database) throws {
        let trimmed = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
        if try database.tableExists("categories", db: db),
           try !database.liveRowExists(table: "categories", rowID: trimmed, db: db) {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
    }

    /// The latest month the budget has data for (budget rows or transactions), as
    /// Actual's created months extend through the budget's latest month.
    private static func lastExistingBudgetMonth(in database: isolated BudgetDatabase, db: Database) throws -> Int {
        try BudgetMonthSQL.fetchAvailableMonths(in: database, db: db).last.map(YearMonth.packedUnchecked) ?? 0
    }
}
