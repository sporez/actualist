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
                    throw LocalFirstError.refusedChange("Enter an amount greater than zero to hold.")
                }
                // The hold below disables this month's automatic hold, so the money it was
                // holding is available to hold, as in Actual's reset-then-hold sequence.
                guard review.holdableAmount > 0 else {
                    throw LocalFirstError.refusedChange("There is no money available to hold.")
                }
                let delta = min(amount, review.holdableAmount)
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
                // With only an automatic hold, release disables it. Otherwise this is Actual's
                // reset-hold: the stored hold becomes zero, whether or not one existed.
                if review.isAutomaticHold {
                    return try resetIncomeCarryoverMessages(
                        month: review.month,
                        db: db,
                        builder: &builder
                    )
                }
                return [try bufferMessage(
                    month: review.month,
                    amount: 0,
                    db: db,
                    builder: &builder
                )]
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
    func resetIncomeCarryoverMessages(
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
                    categoryID: categoryID, monthAsText: true, builder: &builder
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
