import Foundation
import GRDB

enum BudgetHoldSQL {
    /// Amount the budget holds out of `month`'s To Budget (Actual's "hold for next month").
    ///
    /// Actual's envelope sheet keeps a per-month hold cell (loot-core `budget/envelope.ts`
    /// `buffered-selected`): the manual hold stored in `zero_budget_months.buffered`, or —
    /// when there is no explicit hold for the month — the sum of that month's activity in
    /// income categories whose budget row is flagged carryover (`buffered-auto`, an implicit
    /// hold of earmarked income). An explicit non-zero hold always wins over the inferred one.
    ///
    /// To Budget's account-balance derivation accounts for the money held in every *prior*
    /// month automatically: the held cash never left the account balances, and upstream
    /// returns it through `from-last-month`. Only the current month's hold must come out
    /// here, so a hold reduces its own month and returns on its own the following month.
    static func envelopeHold(month: String, in database: isolated BudgetDatabase, db: Database) throws -> Int {
        let manualHold = try manualEnvelopeHold(month: month, in: database, db: db)
        guard manualHold == 0 else {
            return manualHold
        }
        return try inferredIncomeCarryoverHold(month: month, in: database, db: db)
    }

    static func budgetHoldReview(month: String, in database: isolated BudgetDatabase) throws -> BudgetHoldReview {
        try database.queue.read { db in try budgetHoldReview(month: month, in: database, db: db) }
    }

    static func budgetHoldReview(month: String, in database: isolated BudgetDatabase, db: Database) throws -> BudgetHoldReview {
        guard YearMonth.canonicalID(month) == month else {
            throw LocalFirstError.invalidLocalWrite("invalid hold month")
        }
        let table = try database.budgetTable(db: db)
        guard BudgetActionEligibility.allows(.holdForNextMonth, in: table) else {
            throw BudgetModeWriteError.unsupportedAction
        }
        let modeIdentity = try database.budgetModeIdentity(db: db)
        let manualHeldAmount = try manualEnvelopeHold(month: month, in: database, db: db)
        let automaticHeldAmount = try inferredIncomeCarryoverHold(month: month, in: database, db: db)
        let heldAmount = manualHeldAmount == 0 ? automaticHeldAmount : manualHeldAmount
        let revision = try budgetHoldReviewRevision(
            month: month,
            modeIdentity: modeIdentity,
            in: database,
            db: db
        )
        return BudgetHoldReview(
            month: month,
            modeIdentity: modeIdentity,
            currency: try BudgetCurrencySQL.budgetCurrency(in: database, db: db),
            toBudget: try BudgetMonthSQL.envelopeToBudget(month: month, in: database, db: db),
            heldAmount: heldAmount,
            manualHeldAmount: manualHeldAmount,
            automaticHeldAmount: automaticHeldAmount,
            revision: revision
        )
    }

    /// Explicit hold from `zero_budget_months`. Row IDs are sheet months ("2026-08"); some
    /// databases store bare numeric IDs, so they are canonicalized before comparing.
    private static func manualEnvelopeHold(month: String, in database: isolated BudgetDatabase, db: Database) throws -> Int {
        guard try database.tableExists("zero_budget_months", db: db) else {
            return 0
        }
        let columns = try database.columnSet(for: "zero_budget_months", db: db)
        let buffered = database.column("buffered", fallback: "0", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id AS raw_month, \(buffered) AS buffered
                FROM zero_budget_months
                """
        )
        for row in rows where YearMonth.canonicalID(SQLiteValueCoercion.lenientString(row["raw_month"])) == month {
            return row["buffered"] ?? 0
        }
        return 0
    }

    /// Income received into a category whose budget row for `month` is flagged carryover is
    /// treated as held for next month even without an explicit hold row.
    private static func inferredIncomeCarryoverHold(month: String, in database: isolated BudgetDatabase, db: Database) throws -> Int {
        let budgets = try BudgetCategoryValueSQL.categoryBudgets(month: month, in: database, db: db)
        let incomeIDs = try incomeCategoryIDs(in: database, db: db)
        let spending = try BudgetCategoryValueSQL.categorySpending(month: month, in: database, db: db)
        return budgets.reduce(0) { total, entry in
            let (categoryID, budget) = entry
            guard budget.carryover, incomeIDs.contains(categoryID) else {
                return total
            }
            return total + (spending[categoryID] ?? 0)
        }
    }

    private static func incomeCategoryIDs(in database: isolated BudgetDatabase, db: Database) throws -> Set<String> {
        guard try database.tableExists("categories", db: db) else {
            return []
        }
        let columns = try database.columnSet(for: "categories", db: db)
        let isIncome = database.column("is_income", fallback: "0", columns: columns)
        return try Set(
            Row.fetchAll(
                db,
                sql: """
                    SELECT id
                    FROM categories
                    WHERE \(database.predicateForLiveRows(columns: columns)) AND \(isIncome) = 1
                    """
            ).compactMap { $0["id"] as String? }
        )
    }

    private static func budgetHoldReviewRevision(
        month: String,
        modeIdentity: BudgetModeIdentity,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> BudgetHoldReviewRevision {
        let watermark = try database.crdtMessageWatermark(db: db)
        return BudgetHoldReviewRevision(
            month: month,
            modeIdentity: modeIdentity,
            messageCount: watermark.messageCount,
            maxMessageTimestamp: watermark.maxMessageTimestamp
        )
    }

    /// Runs in the same SQLite transaction as the CRDT apply and outbox insert.
    static func validateBudgetHoldReview(_ expected: BudgetHoldReview?, in database: isolated BudgetDatabase, db: Database) throws {
        guard let expected else { return }
        guard expected.revision != nil,
              try budgetHoldReview(month: expected.month, in: database, db: db) == expected else {
            throw LocalFirstError.budgetHoldReviewStale
        }
    }

    static func budgetHoldMessages(
        command: BudgetHoldCommand,
        review: BudgetHoldReview,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        try database.queue.read { db in
            try validateBudgetHoldReview(review, in: database, db: db)
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
                    builder: &builder,
                    in: database,
                    db: db
                )]
                // Desktop dispatches reset-income-carryover with every hold.
                messages.append(contentsOf: try resetIncomeCarryoverMessages(
                    month: review.month,
                    builder: &builder,
                    in: database,
                    db: db
                ))
                return messages
            case .reset:
                // With only an automatic hold, release disables it. Otherwise this is Actual's
                // reset-hold: the stored hold becomes zero, whether or not one existed.
                if review.isAutomaticHold {
                    return try resetIncomeCarryoverMessages(
                        month: review.month,
                        builder: &builder,
                        in: database,
                        db: db
                    )
                }
                return [try bufferMessage(
                    month: review.month,
                    amount: 0,
                    builder: &builder,
                    in: database,
                    db: db
                )]
            }
        }
    }

    private static func bufferMessage(
        month: String,
        amount: Int,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> ActualSyncDecodedMessage {
        _ = try database.requiredColumns(
            table: "zero_budget_months",
            required: ["id", "buffered"],
            db: db
        )
        let matchingRowIDs = try Row.fetchAll(
            db,
            sql: "SELECT id FROM zero_budget_months"
        ).compactMap { row -> String? in
            guard let rowID = SQLiteValueCoercion.lenientString(row["id"]),
                  YearMonth.canonicalID(rowID) == month else {
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
    static func resetIncomeCarryoverMessages(
        month: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        let monthValue = try BudgetDatabase.actualMonthValue(month)
        let table = try database.budgetTable(db: db)
        let columns = try database.requiredColumns(
            table: table.rawValue,
            required: ["month", "category", "carryover"],
            db: db
        )
        var messages: [ActualSyncDecodedMessage] = []
        for categoryID in try incomeCategoryIDs(in: database, db: db).sorted() {
            let existingRowID = try BudgetRowSQL.budgetRowID(
                table: table,
                monthValue: monthValue,
                categoryID: categoryID,
                columns: columns,
                in: database,
                db: db
            )
            let rowID = existingRowID ?? BudgetRowSQL.budgetRowID(
                monthValue: monthValue,
                categoryID: categoryID
            )
            if existingRowID == nil {
                messages += try BudgetRowSQL.budgetRowIdentityMessages(
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
