import Foundation
@testable import Actualist

/// Envelope identities that Actualist's own month read must satisfy, checked against its own values (never the
/// oracle). A failure is strict and is never wrapped in `withKnownIssue`. Tracking months have no To Budget and are
/// not checked.
///
/// Not checked, because Actualist does not expose the inputs: the manual/automatic split of the hold
/// (`buffered`, `buffered-auto`; only the effective `forNextMonth` is exposed), and the on-budget account
/// balance and uncategorized activity that produce `toBudget`.
///
/// Not checked, because it is not one of Actualist's identities: the exposed `lastMonthOverspent`. To Budget
/// takes last month's overspend from `envelopeCarryIn`, not from that field, and no screen or widget reads it.
/// The replay compares it with the oracle instead (OP-35).
enum BudgetMonthConsistency {
    struct Problem: Equatable {
        let field: String
        let expected: Int
        let actual: Int
    }

    /// The month before `month` (`yyyy-MM`).
    static func previousMonth(_ month: String) -> String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return month }
        let index = parts[0] * 12 + parts[1] - 2
        let year = index / 12
        let monthNumber = index % 12 + 1
        return "\(year)-\(monthNumber < 10 ? "0" : "")\(monthNumber)"
    }

    static func problems(month: BudgetMonth, previous: BudgetMonth) -> [Problem] {
        guard month.trackingSummary == nil else { return [] }
        let expense = month.categoryGroups.filter { !$0.isIncome }.flatMap(\.categories)
        let income = month.categoryGroups.filter(\.isIncome).flatMap(\.categories)
        let previousExpense = Dictionary(
            previous.categoryGroups.filter { !$0.isIncome }.flatMap(\.categories).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Last month's overspend from the previous month's category values, as `envelopeCarryIn` derives it.
        var derivedOverspent = 0
        for category in expense where previousExpense[category.id]?.carryover != true {
            derivedOverspent += min(0, previousExpense[category.id]?.balance ?? 0)
        }

        var problems: [Problem] = []
        func require(_ field: String, expected: Int, actual: Int) {
            if expected != actual {
                problems.append(Problem(field: field, expected: expected, actual: actual))
            }
        }
        require("available-funds", expected: month.totalIncome + month.fromLastMonth, actual: month.incomeAvailable)
        require("from-last-month", expected: previous.toBudget + previous.forNextMonth, actual: month.fromLastMonth)
        require("total-budgeted", expected: expense.reduce(0) { $0 + $1.budgeted }, actual: month.totalBudgeted)
        require("total-spent", expected: expense.reduce(0) { $0 + $1.spent }, actual: month.totalSpent)
        require("total-leftover", expected: expense.reduce(0) { $0 + $1.balance }, actual: month.totalBalance)
        require("total-income", expected: income.reduce(0) { $0 + $1.spent }, actual: month.totalIncome)
        require(
            "to-budget",
            expected: month.totalIncome + month.fromLastMonth + derivedOverspent - month.totalBudgeted - month.forNextMonth,
            actual: month.toBudget
        )
        for category in expense {
            guard let prior = previousExpense[category.id] else { continue }
            let carried = prior.carryover ? prior.balance : max(0, prior.balance)
            require(
                "category.\(category.id).leftover",
                expected: category.budgeted + category.spent + carried,
                actual: category.balance
            )
        }
        return problems
    }
}
