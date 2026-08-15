import Foundation
import GRDB

extension BudgetDatabase {
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
    func envelopeHold(month: String, db: Database) throws -> Int {
        let manualHold = try manualEnvelopeHold(month: month, db: db)
        guard manualHold == 0 else {
            return manualHold
        }
        return try inferredIncomeCarryoverHold(month: month, db: db)
    }

    /// Explicit hold from `zero_budget_months`. Row IDs are sheet months ("2026-08"); some
    /// databases store bare numeric IDs, so they are canonicalized before comparing.
    private func manualEnvelopeHold(month: String, db: Database) throws -> Int {
        guard try tableExists("zero_budget_months", db: db) else {
            return 0
        }
        let columns = try columnSet(for: "zero_budget_months", db: db)
        let buffered = column("buffered", fallback: "0", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id AS raw_month, \(buffered) AS buffered
                FROM zero_budget_months
                """
        )
        for row in rows where canonicalMonthID(flexibleString(row["raw_month"])) == month {
            return actualAmountToMinorUnits(row["buffered"] ?? 0)
        }
        return 0
    }

    /// Income received into a category whose budget row for `month` is flagged carryover is
    /// treated as held for next month even without an explicit hold row.
    private func inferredIncomeCarryoverHold(month: String, db: Database) throws -> Int {
        let budgets = try categoryBudgets(month: month, db: db)
        let incomeIDs = try incomeCategoryIDs(db: db)
        let spending = try categorySpending(month: month, db: db)
        return budgets.reduce(0) { total, entry in
            let (categoryID, budget) = entry
            guard budget.carryover, incomeIDs.contains(categoryID) else {
                return total
            }
            return total + (spending[categoryID] ?? 0)
        }
    }

    private func incomeCategoryIDs(db: Database) throws -> Set<String> {
        guard try tableExists("categories", db: db) else {
            return []
        }
        let columns = try columnSet(for: "categories", db: db)
        let isIncome = column("is_income", fallback: "0", columns: columns)
        return try Set(
            Row.fetchAll(
                db,
                sql: """
                    SELECT id
                    FROM categories
                    WHERE \(predicateForLiveRows(columns: columns)) AND \(isIncome) = 1
                    """
            ).compactMap { $0["id"] as String? }
        )
    }
}
