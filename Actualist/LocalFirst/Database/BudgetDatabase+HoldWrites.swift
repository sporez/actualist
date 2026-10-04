import GRDB

extension BudgetDatabase {
    func budgetHoldMessages(
        command: BudgetHoldCommand,
        review: BudgetHoldReview,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            try validateBudgetHoldReview(review, db: db)
            switch command {
            case .hold(let amount):
                guard amount > 0, amount <= Money.maximumUserAmountMinorUnits else {
                    throw LocalFirstError.invalidLocalWrite("invalid hold amount")
                }
                guard review.toBudget > 0 else {
                    throw LocalFirstError.invalidLocalWrite("no money is available to hold")
                }
                // Actual's menu does not offer a manual hold while an automatic
                // income-carryover hold is active.
                guard review.automaticHeldAmount == 0 else {
                    throw LocalFirstError.invalidLocalWrite("disable the automatic hold first")
                }
                let delta = min(amount, review.toBudget)
                let added = review.manualHeldAmount.addingReportingOverflow(delta)
                guard !added.overflow,
                      added.partialValue >= 0,
                      added.partialValue <= Money.maximumUserAmountMinorUnits else {
                    throw LocalFirstError.numericValueOutOfRange
                }
                var messages = [try bufferMessage(
                    month: review.month,
                    amount: added.partialValue,
                    db: db,
                    builder: &builder
                )]
                // Desktop dispatches reset-income-carryover with every hold.
                messages.append(contentsOf: try resetIncomeCarryoverMessages(
                    month: review.month,
                    db: db,
                    builder: &builder
                ))
                return messages
            case .reset:
                if review.manualHeldAmount != 0 {
                    return [try bufferMessage(
                        month: review.month,
                        amount: 0,
                        db: db,
                        builder: &builder
                    )]
                }
                return try resetIncomeCarryoverMessages(
                    month: review.month,
                    db: db,
                    builder: &builder
                )
            }
        }
    }

    private func bufferMessage(
        month: String,
        amount: Int,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> ActualSyncDecodedMessage {
        _ = try requiredColumns(
            table: "zero_budget_months",
            required: ["id", "buffered"],
            db: db
        )
        let matchingRowIDs = try Row.fetchAll(
            db,
            sql: "SELECT id FROM zero_budget_months"
        ).compactMap { row -> String? in
            guard let rowID = flexibleString(row["id"]),
                  canonicalMonthID(rowID) == month else {
                return nil
            }
            return rowID
        }
        guard matchingRowIDs.count <= 1 else {
            throw LocalFirstError.invalidLocalWrite("duplicate hold rows for month")
        }
        return try builder.makeMessage(
            dataset: "zero_budget_months",
            row: matchingRowIDs.first ?? month,
            column: "buffered",
            value: .int(Int64(amount))
        )
    }

    /// Actual resets every live income category for the selected month only.
    /// Existing rows emit only `carryover`; new peer rows also need identity cells.
    private func resetIncomeCarryoverMessages(
        month: String,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let monthValue = try Self.actualMonthValue(month)
        let table = try budgetTable(db: db)
        let columns = try requiredColumns(
            table: table.rawValue,
            required: ["month", "category", "carryover"],
            db: db
        )
        var messages: [ActualSyncDecodedMessage] = []
        for categoryID in try incomeCategoryIDs(db: db).sorted() {
            let existingRowID = try budgetRowID(
                table: table,
                monthValue: monthValue,
                categoryID: categoryID,
                columns: columns,
                db: db
            )
            let rowID = existingRowID ?? Self.budgetRowID(
                monthValue: monthValue,
                categoryID: categoryID
            )
            if existingRowID == nil {
                messages += try budgetRowIdentityMessages(
                    table: table, rowID: rowID, monthValue: monthValue,
                    categoryID: categoryID, builder: &builder
                )
            }
            messages.append(try builder.makeMessage(
                dataset: table.rawValue,
                row: rowID,
                column: "carryover",
                value: .bool(false)
            ))
        }
        return messages
    }
}
