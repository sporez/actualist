import Foundation
import GRDB
@testable import Actualist

/// Replays Hold oracle cases through the production path that `LocalFirstActualStore.applyBudgetHoldAndRefresh`
/// runs: review, draft, commit. Each action is compared on its outcome, the cells it committed, and the
/// state of every oracle month.
@MainActor
enum HoldOracleReplay {
    /// Compared per month. `availableFunds`, the grocery fields, and `salaryCarryover` are not; see the README.
    private static let stateFields = [
        "toBudget", "fromLastMonth", "totalIncome", "totalBudgeted",
        "manualHeldAmount", "automaticHeldAmount", "heldAmount",
    ]

    struct ReplayResult {
        let expected: [String: OracleValue]
        let actual: [String: OracleValue]
    }

    struct CellWrite {
        let dataset: String
        let row: String
        let column: String
        let serialized: String

        var key: String {
            "\(dataset)/\(row)/\(column)"
        }
    }

    /// One comparable replay step: a hold (a UI pair or a standalone hold) or a reset.
    private struct ReplayAction {
        let command: BudgetHoldCommand
        let month: String
        /// The committed flag the oracle recorded. Resets and CRDT replays record none.
        let outcome: Bool?
        /// Cells the oracle committed. A refused hold commits none; its preceding reset is not replayed.
        let cells: [CellWrite]
        let stateAfter: [[String: Any]]
    }

    private static let schemaSQL = """
        CREATE TABLE accounts (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, offbudget INTEGER,
            closed INTEGER, tombstone INTEGER, sort_order INTEGER
        );
        CREATE TABLE category_groups (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, is_income INTEGER,
            hidden INTEGER, tombstone INTEGER, sort_order INTEGER
        );
        CREATE TABLE categories (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, cat_group TEXT, is_income INTEGER,
            hidden INTEGER, tombstone INTEGER, sort_order INTEGER
        );
        CREATE TABLE category_mapping (id TEXT PRIMARY KEY, transferId TEXT);
        CREATE TABLE transactions (
            id TEXT PRIMARY KEY, acct TEXT, date INTEGER, amount INTEGER, category TEXT,
            tombstone INTEGER, parent_id TEXT, is_parent INTEGER,
            error TEXT, reconciled INTEGER, sort_order REAL
        );
        CREATE TABLE zero_budgets (
            id TEXT PRIMARY KEY, month INTEGER, category TEXT, amount INTEGER, carryover INTEGER
        );
        CREATE TABLE zero_budget_months (id TEXT PRIMARY KEY, buffered INTEGER);
        CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE messages_crdt (timestamp TEXT, dataset TEXT, row TEXT, column TEXT, value TEXT);
        INSERT INTO accounts VALUES ('checking', 'Synthetic Checking', 0, 0, 0, 1);
        INSERT INTO category_groups VALUES ('income-group', 'Synthetic Income', 1, 0, 0, 1);
        INSERT INTO category_groups VALUES ('expense-group', 'Synthetic Expenses', 0, 0, 0, 2);
        INSERT INTO categories VALUES ('salary', 'Synthetic Salary', 'income-group', 1, 0, 0, 1);
        INSERT INTO categories VALUES ('groceries', 'Synthetic Groceries', 'expense-group', 0, 0, 0, 2);
        INSERT INTO category_mapping VALUES ('salary', 'salary');
        INSERT INTO category_mapping VALUES ('groceries', 'groceries');
        """

    /// True when the oracle expects a string-typed month identity cell on a budget row (OP-20 territory).
    static func expectsStringMonthCell(_ expected: [String: OracleValue]) -> Bool {
        expected.contains { key, value in
            guard key.contains(".cell."), key.hasSuffix("/month"), case .string(let text) = value else {
                return false
            }
            return text.hasPrefix("S:")
        }
    }

    /// OP-20: the oracle writes a budget row's month identity as text (`S:202607`); Actualist writes a number.
    static func isStringMonthMismatch(_ mismatch: ReplayMismatch) -> Bool {
        guard mismatch.path.contains(".cell."), mismatch.path.hasSuffix("/month"),
              mismatch.expected.hasPrefix("\"S:"), mismatch.actual.hasPrefix("\"N:") else {
            return false
        }
        let expectedDigits = mismatch.expected.dropFirst(3).dropLast()
        return !expectedDigits.isEmpty && expectedDigits == mismatch.actual.dropFirst(3).dropLast()
    }

    static func replay(_ entry: [String: Any]) async throws -> ReplayResult {
        let setup = try OracleJSON.object(entry["setup"], "setup")
        let before = try OracleJSON.objects(entry["before"], "before")
        let months = try before.map { try OracleJSON.string($0, "month") }
        let actions = try plan(try OracleJSON.objects(entry["steps"], "steps"))
        let database = try BudgetDatabase(databaseURL: try makeFixture(setup: setup), localNodeID: "hold-oracle")

        var expected = try stateValues(before, prefix: "before.")
        var actual = try await snapshot(database, months: months, prefix: "before.")
        var builder = LocalFirstSyncMessageBuilder()
        for (index, action) in actions.enumerated() {
            let prefix = "action\(index)."
            let review = try await database.budgetHoldReview(month: action.month)
            var drafts: [ActualSyncDecodedMessage] = []
            var committed = true
            do {
                drafts = try await database.budgetHoldMessages(
                    command: action.command,
                    review: review,
                    builder: &builder
                )
            } catch is LocalFirstError {
                // A refusal writes nothing; the oracle's false outcome is the expectation.
                committed = false
            }
            if committed {
                _ = try await database.commitLocalSyncMessagesAndEnqueue(
                    drafts,
                    expectedMode: review.modeIdentity,
                    expectedHoldReview: review
                )
            }

            if let outcome = action.outcome {
                expected[prefix + "outcome"] = .number(outcome ? 1 : 0)
                actual[prefix + "outcome"] = .number(committed ? 1 : 0)
            }
            expected.merge(cellValues(action.cells, prefix: prefix)) { _, new in new }
            let writes = drafts.map { message in
                CellWrite(
                    dataset: message.dataset,
                    row: message.row,
                    column: message.column,
                    serialized: message.serializedValue
                )
            }
            actual.merge(cellValues(writes, prefix: prefix)) { _, new in new }

            let expectedState = try stateValues(action.stateAfter, prefix: prefix)
            expected.merge(expectedState) { _, new in new }
            let actualState = try await snapshot(database, months: months, prefix: prefix)
            actual.merge(actualState) { _, new in new }
        }
        return ReplayResult(expected: expected, actual: actual)
    }

    /// Pairs each UI hold (`reset-income-carryover` immediately followed by `hold-for-next-month`) into one
    /// hold action. A standalone reset becomes `.reset`. A standalone hold is not replayed.
    private static func plan(_ steps: [[String: Any]]) throws -> [ReplayAction] {
        var actions: [ReplayAction] = []
        var index = 0
        while index < steps.count {
            let step = steps[index]
            if step["kind"] as? String == "apply-messages" {
                let cells = try cellWrites(step)
                guard let buffered = cells.first(where: {
                    $0.dataset == "zero_budget_months" && $0.column == "buffered"
                }), let amount = Int(buffered.serialized.dropFirst(2)) else {
                    throw OracleReplayError.malformedFixture("apply-messages step has no buffered hold")
                }
                actions.append(ReplayAction(
                    command: .hold(amount: amount),
                    month: buffered.row,
                    outcome: nil,
                    cells: cells,
                    stateAfter: try stateAfter(step)
                ))
                index += 1
                continue
            }

            let handler = try OracleJSON.string(step, "handler")
            let next = index + 1 < steps.count ? steps[index + 1] : [:]
            if handler == "budget/reset-income-carryover",
               next["handler"] as? String == "budget/hold-for-next-month" {
                let holdArgs = try OracleJSON.object(next["args"], "args")
                let committed = try boolean(next, "returned")
                let cells = try committed ? (cellWrites(step) + cellWrites(next)) : []
                actions.append(ReplayAction(
                    command: .hold(amount: try intValue(holdArgs, "amount")),
                    month: try OracleJSON.string(holdArgs, "month"),
                    outcome: committed,
                    cells: cells,
                    stateAfter: try stateAfter(next)
                ))
                index += 2
                continue
            }

            guard handler == "budget/reset-income-carryover" || handler == "budget/reset-hold" else {
                throw OracleReplayError.malformedFixture("\(handler) is not replayed")
            }
            let args = try OracleJSON.object(step["args"], "args")
            actions.append(ReplayAction(
                command: .reset,
                month: try OracleJSON.string(args, "month"),
                outcome: nil,
                cells: try cellWrites(step),
                stateAfter: try stateAfter(step)
            ))
            index += 1
        }
        return actions
    }

    /// The seven compared fields for each month, read through production reads. `totalBudgeted` is negated
    /// to match Actual's sheet; every other amount is compared as stored.
    private static func snapshot(
        _ database: BudgetDatabase,
        months: [String],
        prefix: String
    ) async throws -> [String: OracleValue] {
        var values: [String: OracleValue] = [:]
        for month in months {
            let budget = try await database.fetchBudgetMonth(month: month)
            let review = try await database.budgetHoldReview(month: month)
            let fields: [(String, Int)] = [
                ("toBudget", budget.toBudget),
                ("fromLastMonth", budget.fromLastMonth),
                ("totalIncome", budget.totalIncome),
                ("totalBudgeted", -budget.totalBudgeted),
                ("manualHeldAmount", review.manualHeldAmount),
                ("automaticHeldAmount", review.automaticHeldAmount),
                ("heldAmount", review.heldAmount),
            ]
            for (field, value) in fields {
                values["\(prefix)\(month).\(field)"] = .number(Double(value))
            }
        }
        return values
    }

    private static func stateValues(_ states: [[String: Any]], prefix: String) throws -> [String: OracleValue] {
        var values: [String: OracleValue] = [:]
        for state in states {
            let month = try OracleJSON.string(state, "month")
            for field in stateFields {
                values["\(prefix)\(month).\(field)"] = try OracleValue(json: state[field] ?? NSNull())
            }
        }
        return values
    }

    /// Cells keyed `cell.<dataset>/<row>/<column>`. Values for one key are sorted and joined, so a key
    /// written twice compares as a set.
    static func cellValues(_ writes: [CellWrite], prefix: String) -> [String: OracleValue] {
        var values: [String: OracleValue] = [:]
        for (key, group) in Dictionary(grouping: writes, by: \.key) {
            values["\(prefix)cell.\(key)"] = .string(group.map(\.serialized).sorted().joined(separator: "|"))
        }
        return values
    }

    private static func cellWrites(_ step: [String: Any]) throws -> [CellWrite] {
        guard let cells = step["cells"] else {
            return []
        }
        return try OracleJSON.objects(cells, "cells").map { cell in
            CellWrite(
                dataset: try OracleJSON.string(cell, "dataset"),
                row: try OracleJSON.string(cell, "row"),
                column: try OracleJSON.string(cell, "column"),
                serialized: try OracleJSON.string(cell, "serializedValue")
            )
        }
    }

    private static func stateAfter(_ step: [String: Any]) throws -> [[String: Any]] {
        try OracleJSON.objects(step["stateAfter"], "stateAfter")
    }

    private static func boolean(_ object: [String: Any], _ key: String) throws -> Bool {
        guard let value = (object[key] as? NSNumber)?.boolValue else {
            throw OracleReplayError.malformedFixture("\(key) is not a boolean")
        }
        return value
    }

    private static func intValue(_ object: [String: Any], _ key: String) throws -> Int {
        guard let value = OracleJSON.int(object[key]) else {
            throw OracleReplayError.malformedFixture("\(key) is not an integer")
        }
        return value
    }

    /// A synthetic envelope budget seeded from the oracle's `setup`, the same rows `generate.mjs` seeds.
    private static func makeFixture(setup: [String: Any]) throws -> URL {
        guard try OracleJSON.string(setup, "budgetType") == "envelope" else {
            throw OracleReplayError.malformedFixture("only envelope budgets are replayed")
        }
        var incomes: [(id: String, date: Int, amount: Int)] = []
        for (id, date, key) in [
            ("income-june", 20_260_601, "juneIncome"),
            ("income-july", 20_260_701, "julyIncome"),
            ("income-august", 20_260_801, "augustIncome"),
        ] {
            let amount = try intValue(setup, key)
            if amount != 0 {
                incomes.append((id: id, date: date, amount: amount))
            }
        }
        let julyGroceries = try intValue(setup, "julyGroceriesBudget")
        let julyBuffer = try intValue(setup, "julyManualBuffer")
        let julyCarryover = try boolean(setup, "julyIncomeCarryover")
        let augustCarryover = try boolean(setup, "augustIncomeCarryover")

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "HoldOracleReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "db.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: schemaSQL)
            for income in incomes {
                try db.execute(
                    sql: """
                        INSERT INTO transactions
                        VALUES (?, 'checking', ?, ?, 'salary', 0, NULL, 0, NULL, 0, 0)
                        """,
                    arguments: [income.id, income.date, income.amount]
                )
            }
            if julyGroceries != 0 {
                try db.execute(
                    sql: """
                        INSERT INTO zero_budgets VALUES ('202607-groceries', 202607, 'groceries', ?, 0)
                        """,
                    arguments: [julyGroceries]
                )
            }
            if julyCarryover {
                try db.execute(sql: "INSERT INTO zero_budgets VALUES ('202607-salary', 202607, 'salary', 0, 1)")
            }
            if augustCarryover {
                try db.execute(sql: "INSERT INTO zero_budgets VALUES ('202608-salary', 202608, 'salary', 0, 1)")
            }
            if julyBuffer != 0 {
                try db.execute(
                    sql: "INSERT INTO zero_budget_months VALUES ('2026-07', ?)",
                    arguments: [julyBuffer]
                )
            }
        }
        return url
    }
}
