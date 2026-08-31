import Foundation
import GRDB
@testable import Actualist

extension LocalFirstActualStoreTests {
    struct BudgetTemplateApplySingleStoredRow: Equatable, Sendable {
        let amount: Int
        var goal: Int?
        var longGoal: Int?
        var carryover: Int

        init(amount: Int, goal: Int? = nil, longGoal: Int? = nil, carryover: Int = 0) {
            self.amount = amount
            self.goal = goal
            self.longGoal = longGoal
            self.carryover = carryover
        }
    }

    func budgetTemplateApplySingleRow(
        table: String,
        categoryID: String,
        month: Int,
        at databaseURL: URL
    ) throws -> BudgetTemplateApplySingleStoredRow? {
        try budgetTemplateApplySingleRows(table: table, month: month, at: databaseURL)[categoryID]
    }

    func budgetTemplateApplySingleRows(
        table: String,
        month: Int,
        at databaseURL: URL
    ) throws -> [String: BudgetTemplateApplySingleStoredRow] {
        precondition(["zero_budgets", "reflect_budgets"].contains(table))
        let queue = try DatabaseQueue(path: databaseURL.path)
        return try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT category, amount, goal, long_goal, carryover
                    FROM \(table)
                    WHERE month = ?
                    """,
                arguments: [month]
            )
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let category = row["category"] as String? else { return nil }
                return (
                    category,
                    BudgetTemplateApplySingleStoredRow(
                        amount: row["amount"] ?? 0,
                        goal: row["goal"],
                        longGoal: row["long_goal"],
                        carryover: row["carryover"] ?? 0
                    )
                )
            })
        }
    }
}
