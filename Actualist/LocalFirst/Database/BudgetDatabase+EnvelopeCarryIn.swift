import Foundation
import GRDB

extension BudgetDatabase {
    struct EnvelopeCarryIn: Equatable {
        /// Upstream `from-last-month`: previous `to-budget` plus previous `buffered-selected`.
        let fromLastMonth: Int
        /// Upstream `last-month-overspent`: previous leftover below zero, summed over
        /// expense categories without carryover.
        let lastMonthOverspent: Int
    }

    /// Envelope month values from loot-core `budget/envelope.ts`, derived from the
    /// previous month's category values so a month read needs no second recurrence.
    /// Identity: `toBudget == totalIncome + fromLastMonth + lastMonthOverspent
    /// - totalBudgeted - forNextMonth`.
    func envelopeCarryIn(
        month: String,
        groups: [BudgetMonthCategoryGroup],
        previousValues: [String: BudgetCategoryValue],
        db: Database
    ) throws -> EnvelopeCarryIn {
        let previousMonth = monthID(shiftedMonth(monthInt(month), by: -1))
        let expenseCategoryIDs = groups.filter { !$0.isIncome }.flatMap(\.categories).map(\.id)
        let previous = expenseCategoryIDs.map { previousValues[$0] ?? BudgetCategoryValue() }
        let previousAvailability = try envelopeAvailability(
            month: previousMonth,
            totalBalance: try BudgetFinancialCalculation.sum(previous.map(\.balance), table: .envelope),
            db: db
        )
        let overspent = try BudgetFinancialCalculation.sum(
            previous.filter { !$0.carryover }.map { min(0, $0.balance) },
            table: .envelope
        )
        return EnvelopeCarryIn(
            fromLastMonth: try BudgetTemplateEngine.checkedAdd(
                previousAvailability.toBudget,
                previousAvailability.holdForNextMonth
            ),
            lastMonthOverspent: overspent
        )
    }
}
