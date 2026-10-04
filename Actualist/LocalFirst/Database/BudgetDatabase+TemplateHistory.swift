import Foundation
import GRDB

/// One template plan's shared read of budget and spending history. The
/// budget/spending tables are read once and the month recurrence runs once
/// forward, instead of once per category, per month and per Apply mode.
/// Not `Sendable`: create it inside one database read and drop it with it.
final class TemplateHistory {
    fileprivate var inputs: BudgetCategoryValueInputs?
    fileprivate var firstBudgetMonthByCategory: [String: String]?
    fileprivate var keptRange: ClosedRange<Int>?
    fileprivate var snapshots: [Int: [String: BudgetCategoryValue]] = [:]
    /// Reads of the budget and spending tables; the work-count seam for tests.
    private(set) var inputLoadCount = 0

    fileprivate func recordInputLoad() {
        inputLoadCount += 1
    }
}

extension BudgetDatabase {
    func templateHistoryInputs(
        _ history: TemplateHistory,
        db: Database
    ) throws -> BudgetCategoryValueInputs {
        if let inputs = history.inputs {
            return inputs
        }
        let inputs = try categoryValueInputs(db: db)
        history.inputs = inputs
        history.recordInputLoad()
        return inputs
    }

    /// Values for `month` (Actual's `leftover` family). The first request runs
    /// the recurrence forward through `month`, keeping snapshots from
    /// `keepFrom`; later requests inside that range are lookups.
    func templateHistoryCategoryValues(
        _ history: TemplateHistory,
        at month: Int,
        keepFrom: Int,
        db: Database
    ) throws -> [String: BudgetCategoryValue] {
        let inputs = try templateHistoryInputs(history, db: db)
        if let range = history.keptRange, range.contains(month) {
            if let kept = history.snapshots[month] {
                return kept
            }
            // Precedes the first month with real data: a one-month recurrence.
            return try categoryValueTimeline(inputs: inputs, through: month, keepFrom: month)
                .snapshots[month] ?? [:]
        }
        let upper = max(month, history.keptRange?.upperBound ?? month)
        let lower = min(keepFrom, month, history.keptRange?.lowerBound ?? month)
        let timeline = try categoryValueTimeline(inputs: inputs, through: upper, keepFrom: lower)
        history.snapshots = timeline.snapshots
        history.keptRange = lower...upper
        if let kept = timeline.snapshots[month] {
            return kept
        }
        // `month` precedes the first month with real data.
        return try categoryValueTimeline(inputs: inputs, through: month, keepFrom: month)
            .snapshots[month] ?? [:]
    }

    /// Earliest stored budget month for a category (`MIN(month)` over its rows).
    func templateHistoryFirstBudgetMonth(
        _ history: TemplateHistory,
        categoryID: String,
        db: Database
    ) throws -> Int? {
        if history.firstBudgetMonthByCategory == nil {
            var earliest: [String: String] = [:]
            for (month, byCategory) in try templateHistoryInputs(history, db: db).budgetedByMonth {
                for categoryID in byCategory.keys {
                    if let current = earliest[categoryID], current <= month { continue }
                    earliest[categoryID] = month
                }
            }
            history.firstBudgetMonthByCategory = earliest
        }
        return history.firstBudgetMonthByCategory?[categoryID]
            .flatMap { try? BudgetTemplateCalendar.parseMonth($0) }
    }
}
