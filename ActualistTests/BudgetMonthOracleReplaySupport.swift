import Foundation
import GRDB
@testable import Actualist

/// Replays BudgetMonth oracle cases through the production budget write seams that
/// `LocalFirstActualStore` calls: assign, move (transfer, cover, and transfer-available), set-carryover,
/// and hold or reset. Each step is read back through `fetchBudgetSnapshot`. Field mapping and the
/// upstream-only fields that are not compared are in `scripts/budget-month-parity/README.md`.
@MainActor
enum BudgetMonthOracleReplay {
    /// 2026-10-15T00:00:00Z, the fixture's `today`. Production reads the wall clock for the carryover
    /// horizon, so the replay computes the same horizon from this fixed date.
    static let fixtureNow = Date(timeIntervalSince1970: 1_792_022_400)

    /// Summary fields compared. `last-month-overspent` is compared as OP-35 (Actualist exposes 0). Other summary
    /// fields in the fixture (`buffered`, `buffered-auto`) are not compared; see the README.
    private static let comparedSummaryFields: Set<String> = [
        "to-budget", "available-funds", "from-last-month", "buffered-selected",
        "total-income", "total-budgeted", "total-spent", "total-leftover",
        "total-budget-income", "total-saved", "real-saved", "last-month-overspent",
    ]

    /// Category fields compared. `spentWithCarryover` and `leftoverPositive` are upstream-only.
    private static let comparedCategoryFields: Set<String> = ["budgeted", "spent", "leftover", "carryover"]

    /// Input tables, cleared of starter rows before the setup is inserted.
    private static let seedTables = [
        "accounts", "category_groups", "categories", "category_mapping", "transactions",
        "zero_budgets", "reflect_budgets", "zero_budget_months", "preferences", "notes",
    ]

    struct ReplayResult {
        /// Two-way mismatches over the flattened fixture fields, plus Actualist's own identity failures
        /// (`.consistency.` paths, `BudgetMonthConsistency`). Paths begin `before.`, `step<n>.`, or `final.` and
        /// name the month and field, so each one names its step and month.
        let mismatches: [ReplayMismatch]
        /// Production refusals, one per action that threw. The state after the action is still compared.
        let refusals: [String]
        /// Oracle states whose `last-month-overspent` is nonzero, with whether To Budget still matched.
        let overspentStates: [String]
        /// Set when a standalone `reset-income-carryover` met a stored manual hold. The replay stops before that
        /// step, so later steps and the final states are not compared for this case.
        let seamGap: String?
        /// Handler family of each replayed step index (`hold` for a paired UI hold). Keys the divergence split.
        let stepLabels: [Int: String]
    }

    private enum Kind {
        case assign(month: String, categoryID: String, budgeted: Int)
        case move(month: String, commands: [BudgetMoveMoneyCommand])
        /// A cover with no fixture amount. The amount is the target category's overspend at commit time,
        /// as `OverspentCoverSelectionWorkflow.coverCommands` derives it; no command when that is not positive.
        case cover(month: String, to: String, from: String?)
        case carryover(categoryID: String, carryover: Bool, startMonth: String)
        case hold(month: String, amount: Int)
        /// `reset-hold`: the hold review's reset, as the store's release action sends it.
        case reset(month: String)
        /// A standalone `reset-income-carryover`. Production has no seam for it: the income-carryover reset is
        /// private and reachable only through the hold review, which also clears a manual hold.
        case incomeCarryoverReset(month: String)
    }

    /// One comparable action. A UI hold is the oracle's `reset-income-carryover` followed by
    /// `hold-for-next-month`, so its step index is the reset's.
    private struct Action {
        let stepIndex: Int
        let kind: Kind
        /// Cells the oracle committed. A refused hold commits none.
        let cells: [CellWrite]
        let stateAfter: [[String: Any]]
        /// The oracle's `returned` for a hold; nil for every other action.
        let returned: Bool?
        /// The step's handler family (`stepLabel`), kept for the divergence split.
        let label: String
    }

    /// The cell shape `HoldOracleReplay` compares, so both replays key cells identically.
    private typealias CellWrite = HoldOracleReplay.CellWrite

    private struct Written {
        let drafts: [ActualSyncDecodedMessage]
        let committed: Bool
        let refusal: String?
    }

    private struct SeedRow: Sendable {
        let sql: String
        let values: [DatabaseValue]
    }

    private struct StateCheck {
        let expected: [String: OracleValue]
        let actual: [String: OracleValue]
        let overspent: String?
        /// Actualist's own envelope identities that fail (`BudgetMonthConsistency`). Never compared with the oracle.
        let consistency: [ReplayMismatch]
    }

    // MARK: Replay

    static func replay(_ entry: [String: Any]) async throws -> ReplayResult {
        let setup = try OracleJSON.object(entry["setup"], "setup")
        let before = try OracleJSON.objects(entry["before"], "before")
        let actions = try plan(try OracleJSON.objects(entry["steps"], "steps"))
        let finalStates = try OracleJSON.objects(entry["expected"], "expected")

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BudgetMonthOracleReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "db.sqlite")
        _ = try BudgetDatabase.makeNewBudgetStarterDatabase(at: url)
        // The starter factory opens without a local node id; reopening with one sets the clock that writes need.
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node1")
        try await seed(database, rows: try seedRows(setup))

        var expected: [String: OracleValue] = [:]
        var actual: [String: OracleValue] = [:]
        var refusals: [String] = []
        var overspentStates: [String] = []
        var consistency: [ReplayMismatch] = []

        for state in before {
            let check = try await readState(database, state, prefix: "before.")
            merge(check, into: &expected, &actual, &overspentStates, &consistency)
        }

        var seamGap: String?
        for action in actions {
            if let gap = try await unreplayableReason(action.kind, database) {
                seamGap = "step \(action.stepIndex): \(gap)"
                break
            }
            let prefix = "step\(action.stepIndex)."
            let written = try await write(action, database)
            if let refusal = written.refusal {
                refusals.append("step \(action.stepIndex): \(refusal)")
            }
            if let returned = action.returned {
                expected["\(prefix)outcome"] = .number(returned ? 1 : 0)
                actual["\(prefix)outcome"] = .number(written.committed ? 1 : 0)
            }
            expected.merge(HoldOracleReplay.cellValues(action.cells, prefix: prefix)) { _, new in new }
            actual.merge(HoldOracleReplay.cellValues(written.drafts.map(cellWrite), prefix: prefix)) { _, new in new }
            for state in action.stateAfter {
                let check = try await readState(database, state, prefix: prefix)
                merge(check, into: &expected, &actual, &overspentStates, &consistency)
            }
        }

        if seamGap == nil {
            for state in finalStates {
                let check = try await readState(database, state, prefix: "final.")
                merge(check, into: &expected, &actual, &overspentStates, &consistency)
            }
        }

        var comparison = OracleComparison()
        comparison.compare(expected: .object(expected), actual: .object(actual))
        return ReplayResult(
            mismatches: comparison.mismatches + consistency,
            refusals: refusals,
            overspentStates: overspentStates,
            seamGap: seamGap,
            stepLabels: Dictionary(uniqueKeysWithValues: actions.map { ($0.stepIndex, $0.label) })
        )
    }

    /// The reason a step cannot be replayed faithfully, or nil (`ReplayResult.seamGap`). Only a standalone
    /// income-carryover reset with a stored manual hold qualifies: production's reset in that state clears the
    /// hold and leaves the income carryover rows alone, which is the reverse of the oracle's action.
    private static func unreplayableReason(_ kind: Kind, _ database: BudgetDatabase) async throws -> String? {
        guard case let .incomeCarryoverReset(month) = kind else {
            return nil
        }
        let review = try await database.budgetHoldReview(month: month)
        return review.manualHeldAmount == 0
            ? nil
            : "standalone reset-income-carryover with a stored manual hold has no production seam"
    }

    private static func merge(
        _ check: StateCheck,
        into expected: inout [String: OracleValue],
        _ actual: inout [String: OracleValue],
        _ overspentStates: inout [String],
        _ consistency: inout [ReplayMismatch]
    ) {
        expected.merge(check.expected) { _, new in new }
        actual.merge(check.actual) { _, new in new }
        consistency.append(contentsOf: check.consistency)
        if let overspent = check.overspent {
            overspentStates.append(overspent)
        }
    }

    private static func write(_ action: Action, _ database: BudgetDatabase) async throws -> Written {
        do {
            let drafts = try await commit(action.kind, database)
            return Written(drafts: drafts, committed: true, refusal: nil)
        } catch let error as LocalFirstError {
            return Written(drafts: [], committed: false, refusal: String(describing: error))
        } catch let error as BudgetModeWriteError {
            return Written(drafts: [], committed: false, refusal: String(describing: error))
        }
    }

    /// Each arm mirrors the store method named in its comment, with the same database seams.
    private static func commit(_ kind: Kind, _ database: BudgetDatabase) async throws -> [ActualSyncDecodedMessage] {
        let mode = try await database.requireBudgetMode(nil)
        switch kind {
        case let .assign(month, categoryID, budgeted):
            // LocalFirstActualStore+AssignMove.assignAndRefresh
            var builder = LocalFirstSyncMessageBuilder()
            let drafts = try await database.assignCategoryBudgetMessages(
                categoryID: categoryID,
                budgeted: budgeted,
                month: month,
                builder: &builder
            )
            _ = try await database.commitUserAction(
                drafts,
                descriptor: .assign(month: month, categoryID: categoryID, budgeted: budgeted),
                source: .ui,
                expectedMode: mode
            )
            return drafts
        case let .move(month, commands):
            // LocalFirstActualStore+AssignMove.moveMoneyAndRefresh. Transfer-available and cover are the
            // same command shape: a nil source is To Budget.
            return try await commitMove(month: month, database, mode, commands: commands)
        case let .cover(month, to, from):
            // OverspentCoverSelectionWorkflow.coverCommands. The overspend is read before the write, which is
            // equivalent here because the replay is sequential and no sync lands between the read and the commit.
            let balance = try await database.fetchBudgetMonth(month: month)
                .categoryGroups.flatMap(\.categories).first { $0.id == to }?.balance ?? 0
            let commands = balance < 0
                ? [BudgetMoveMoneyCommand(fromCategoryID: from, toCategoryID: to, amount: -balance)]
                : []
            return try await commitMove(month: month, database, mode, commands: commands)
        case let .carryover(categoryID, carryover, startMonth):
            // LocalFirstActualStore+Mutations.setCategoryCarryoverAndRefresh
            var builder = LocalFirstSyncMessageBuilder()
            let drafts = try await database.categoryCarryoverMessages(
                categoryID: categoryID,
                carryover: carryover,
                startMonth: startMonth,
                throughMonth: carryoverHorizon(startMonth),
                builder: &builder
            )
            _ = try await database.commitUserAction(
                drafts,
                descriptor: .carryover(CarryoverActionDescriptor(
                    startMonth: startMonth,
                    after: carryover,
                    categoryCount: 1
                )),
                source: .ui,
                expectedMode: mode
            )
            return drafts
        case let .hold(month, amount):
            // LocalFirstActualStore+Holds.applyBudgetHoldAndRefresh
            return try await commitHold(.hold(amount: amount), month: month, database)
        case let .reset(month):
            return try await commitHold(.reset, month: month, database)
        case let .incomeCarryoverReset(month):
            // Reached only when no manual hold is stored (see `seamGap`), where the hold review's reset writes
            // exactly the income-carryover rows.
            return try await commitHold(.reset, month: month, database)
        }
    }

    /// Builds the move inside the write transaction. An empty command list commits no History row.
    private static func commitMove(
        month: String,
        _ database: BudgetDatabase,
        _ mode: BudgetModeIdentity,
        commands: [BudgetMoveMoneyCommand]
    ) async throws -> [ActualSyncDecodedMessage] {
        let applied = try await database.commitUserActionPlan(source: .ui, expectedMode: mode) { budget, db in
            var builder = LocalFirstSyncMessageBuilder()
            let drafts = try budget.moveMoneyMessages(commands: commands, month: month, db: db, builder: &builder)
            let descriptor: BudgetActionDescriptor? = commands.isEmpty ? nil : .move(
                month: month,
                legs: commands.map {
                    BudgetMoveLeg(fromCategoryID: $0.fromCategoryID, toCategoryID: $0.toCategoryID, amount: $0.amount)
                }
            )
            return UserActionPlan(drafts: drafts, descriptor: descriptor, outcome: drafts)
        }
        return applied.outcome
    }

    private static func commitHold(
        _ command: BudgetHoldCommand,
        month: String,
        _ database: BudgetDatabase
    ) async throws -> [ActualSyncDecodedMessage] {
        let review = try await database.budgetHoldReview(month: month)
        var builder = LocalFirstSyncMessageBuilder()
        let drafts = try await database.budgetHoldMessages(command: command, review: review, builder: &builder)
        _ = try await database.commitLocalSyncMessagesAndEnqueue(
            drafts,
            expectedMode: review.modeIdentity,
            expectedHoldReview: review
        )
        return drafts
    }

    /// `LocalFirstActualStore.categoryCarryoverHorizonMonth`, computed from the replay's fixed clock.
    private static func carryoverHorizon(_ startMonth: String) -> String {
        let horizon = Calendar(identifier: .gregorian).date(byAdding: .month, value: 12, to: fixtureNow) ?? fixtureNow
        return max(startMonth, YearMonth(date: horizon).rawValue)
    }

    // MARK: Planning

    /// Pairs each UI hold (`reset-income-carryover` then `hold-for-next-month`) into one hold action.
    /// A reset with no following hold is a standalone `.reset`. A standalone hold is not replayed.
    private static func plan(_ steps: [[String: Any]]) throws -> [Action] {
        var actions: [Action] = []
        var index = 0
        while index < steps.count {
            let step = steps[index]
            let handler = try OracleJSON.string(step, "handler")
            let next = index + 1 < steps.count ? steps[index + 1] : [:]
            if handler == "budget/reset-income-carryover", next["handler"] as? String == "budget/hold-for-next-month" {
                let holdArgs = try OracleJSON.object(next["args"], "args of step \(index + 1)")
                let committed = try boolean(next, "returned")
                let cells = try committed ? cellWrites(step) + cellWrites(next) : []
                actions.append(Action(
                    stepIndex: index,
                    kind: .hold(month: try OracleJSON.string(holdArgs, "month"), amount: try integer(holdArgs, "amount")),
                    cells: cells,
                    stateAfter: try stateAfter(next),
                    returned: committed,
                    label: "hold"
                ))
                index += 2
                continue
            }

            let args = try OracleJSON.object(step["args"], "args of step \(index)")
            let kind: Kind
            switch handler {
            case "budget/budget-amount":
                kind = .assign(
                    month: try OracleJSON.string(args, "month"),
                    categoryID: try OracleJSON.string(args, "category"),
                    budgeted: try integer(args, "amount")
                )
            case "budget/transfer-category":
                kind = try move(
                    args,
                    from: budgetCategory(try OracleJSON.string(args, "from")),
                    to: budgetCategory(try OracleJSON.string(args, "to"))
                )
            case "budget/transfer-available":
                kind = try move(args, from: nil, to: OracleJSON.string(args, "category"))
            case "budget/cover-overspending":
                let from = budgetCategory(try OracleJSON.string(args, "from"))
                let to = try OracleJSON.string(args, "to")
                if args["amount"] == nil || args["amount"] is NSNull {
                    kind = .cover(month: try OracleJSON.string(args, "month"), to: to, from: from)
                } else {
                    // An explicit fixture amount is replayed as given.
                    kind = try move(args, from: from, to: to)
                }
            case "budget/set-carryover":
                kind = .carryover(
                    categoryID: try OracleJSON.string(args, "category"),
                    carryover: try boolean(args, "flag"),
                    startMonth: try OracleJSON.string(args, "startMonth")
                )
            case "budget/reset-hold":
                kind = .reset(month: try OracleJSON.string(args, "month"))
            case "budget/reset-income-carryover":
                kind = .incomeCarryoverReset(month: try OracleJSON.string(args, "month"))
            default:
                throw OracleReplayError.malformedFixture("\(handler) is not replayed")
            }
            actions.append(Action(
                stepIndex: index,
                kind: kind,
                cells: try cellWrites(step),
                stateAfter: try stateAfter(step),
                returned: nil,
                label: stepLabel(handler, kind)
            ))
            index += 1
        }
        return actions
    }

    /// The fixture's handler family. A cover with a fixture amount is a transfer, and so is `transfer-category`.
    private static func stepLabel(_ handler: String, _ kind: Kind) -> String {
        switch kind {
        case .assign: "assign"
        case .move: handler == "budget/transfer-available" ? "transfer-available" : "transfer-category"
        case .cover: "cover"
        case .carryover: "carryover"
        case .hold: "hold"
        case .reset: "reset"
        case .incomeCarryoverReset: "incomeCarryoverReset"
        }
    }

    /// The fixture names To Budget as the literal `"to-budget"`; production represents it as a nil category.
    private static func budgetCategory(_ id: String) -> String? {
        id == "to-budget" ? nil : id
    }

    /// A single-leg move. A nil side is To Budget; `amount` comes from the fixture as given.
    private static func move(_ args: [String: Any], from: String?, to: String?) throws -> Kind {
        .move(
            month: try OracleJSON.string(args, "month"),
            commands: [BudgetMoveMoneyCommand(
                fromCategoryID: from,
                toCategoryID: to,
                amount: try integer(args, "amount")
            )]
        )
    }

    // MARK: Seeding

    private static func seed(_ database: BudgetDatabase, rows: [SeedRow]) async throws {
        let queue = await database.queue
        let tables = Array(seedTables.reversed())
        try await queue.write { db in
            for table in tables {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            for row in rows {
                try db.execute(sql: row.sql, arguments: StatementArguments(row.values as [any DatabaseValueConvertible]))
            }
        }
    }

    /// Rows that `generate.mjs` seeds from `setup`. Only the setup's own budget rows are inserted; the
    /// oracle's expense-category zero rows are not, because Actualist reads an absent row as zero.
    private static func seedRows(_ setup: [String: Any]) throws -> [SeedRow] {
        let budgetType = try OracleJSON.string(setup, "budgetType")
        guard budgetType == "envelope" || budgetType == "tracking" else {
            throw OracleReplayError.malformedFixture("unknown budgetType \(budgetType)")
        }
        let budgetTable = budgetType == "tracking" ? "reflect_budgets" : "zero_budgets"
        var rows = [row("INSERT INTO preferences (id, value) VALUES (?, ?)", ["budgetType", budgetType])]

        for (index, group) in try OracleJSON.objects(setup["groups"], "groups").enumerated() {
            rows.append(row(
                "INSERT INTO category_groups (id, name, is_income, hidden, tombstone, sort_order) VALUES (?, ?, ?, ?, 0, ?)",
                [try OracleJSON.string(group, "id"), try OracleJSON.string(group, "name"),
                 flag(group, "income"), flag(group, "hidden"), index]
            ))
        }
        for (index, category) in try OracleJSON.objects(setup["categories"], "categories").enumerated() {
            let id = try OracleJSON.string(category, "id")
            rows.append(row(
                "INSERT INTO categories (id, name, is_income, cat_group, hidden, tombstone, sort_order) VALUES (?, ?, ?, ?, ?, 0, ?)",
                [id, try OracleJSON.string(category, "name"), flag(category, "income"),
                 try OracleJSON.string(category, "group"), flag(category, "hidden"), index]
            ))
            rows.append(row("INSERT INTO category_mapping (id, transferId) VALUES (?, ?)", [id, id]))
        }
        for (index, account) in try OracleJSON.objects(setup["accounts"], "accounts").enumerated() {
            rows.append(row(
                "INSERT INTO accounts (id, name, offbudget, closed, tombstone, sort_order) VALUES (?, ?, ?, 0, 0, ?)",
                [try OracleJSON.string(account, "id"), try OracleJSON.string(account, "name"),
                 flag(account, "offbudget"), index]
            ))
        }
        for transaction in try OracleJSON.objects(setup["transactions"], "transactions") {
            let category: DatabaseValue = (transaction["category"] as? String)?.databaseValue ?? .null
            rows.append(SeedRow(
                sql: "INSERT INTO transactions (id, acct, category, amount, date, isParent, isChild, tombstone) VALUES (?, ?, ?, ?, ?, 0, 0, 0)",
                values: [
                    try OracleJSON.string(transaction, "id").databaseValue,
                    try OracleJSON.string(transaction, "account").databaseValue,
                    category,
                    try integer(transaction, "amount").databaseValue,
                    try compactInteger(transaction, "date").databaseValue,
                ]
            ))
        }
        for budget in try OracleJSON.objects(setup["budgets"], "budgets") {
            let month = try compactInteger(budget, "month")
            let category = try OracleJSON.string(budget, "category")
            rows.append(row(
                "INSERT INTO \(budgetTable) (id, month, category, amount, carryover) VALUES (?, ?, ?, ?, ?)",
                ["\(month)-\(category)", month, category, try integer(budget, "amount"), flag(budget, "carryover")]
            ))
        }
        for buffer in try OracleJSON.objects(setup["buffers"], "buffers") {
            rows.append(row(
                "INSERT INTO zero_budget_months (id, buffered) VALUES (?, ?)",
                [try OracleJSON.string(buffer, "month"), try integer(buffer, "buffered")]
            ))
        }
        return rows
    }

    private static func row(_ sql: String, _ values: [any DatabaseValueConvertible]) -> SeedRow {
        SeedRow(sql: sql, values: values.map(\.databaseValue))
    }

    // MARK: Reading

    /// The oracle state for one month, and the same fields read from Actualist. Actual fields are kept
    /// only where the oracle has a value, so a null expectation is not compared.
    private static func readState(
        _ database: BudgetDatabase,
        _ state: [String: Any],
        prefix: String
    ) async throws -> StateCheck {
        let monthID = try OracleJSON.string(state, "month")
        let expected = try expectedValues(state, prefix: prefix)
        let month = try await database.fetchBudgetSnapshot(month: monthID, now: fixtureNow).month
        let previous = try await database.fetchBudgetSnapshot(
            month: BudgetMonthConsistency.previousMonth(monthID), now: fixtureNow
        ).month
        let actual = actualValues(month, prefix: prefix).filter { expected[$0.key] != nil }
        let consistency = BudgetMonthConsistency.problems(month: month, previous: previous).map {
            ReplayMismatch(
                path: "\(prefix)\(monthID).consistency.\($0.field)",
                expected: String($0.expected),
                actual: String($0.actual)
            )
        }

        var overspent: String?
        let summary = try OracleJSON.object(state["summary"], "summary of \(monthID)")
        if let lastMonthOverspent = OracleJSON.double(summary["last-month-overspent"]), lastMonthOverspent != 0 {
            let matched = expected["\(prefix)\(monthID).to-budget"] == .number(Double(month.toBudget))
            overspent = "\(prefix)\(monthID) last-month-overspent \(Int(lastMonthOverspent)), to-budget \(matched ? "matched" : "differs")"
        }
        return StateCheck(expected: expected, actual: actual, overspent: overspent, consistency: consistency)
    }

    private static func expectedValues(_ state: [String: Any], prefix: String) throws -> [String: OracleValue] {
        let monthID = try OracleJSON.string(state, "month")
        var values: [String: OracleValue] = [:]
        let summary = try OracleJSON.object(state["summary"], "summary of \(monthID)")
        for (field, value) in summary where comparedSummaryFields.contains(field) {
            if let number = OracleJSON.double(value) {
                values["\(prefix)\(monthID).\(field)"] = .number(number)
            }
        }
        let categories = try OracleJSON.object(state["categories"], "categories of \(monthID)")
        for (id, fields) in categories {
            let category = try OracleJSON.object(fields, "category \(id) of \(monthID)")
            for (field, value) in category where comparedCategoryFields.contains(field) {
                if let number = OracleJSON.double(value) {
                    values["\(prefix)\(monthID).category.\(id).\(field)"] = .number(number)
                }
            }
        }
        return values
    }

    /// The same keys as `expectedValues`, read from Actualist. `total-budgeted` is negated for envelope months to
    /// match Actual's sheet, as `HoldOracleReplay` does. `leftover` reads the category's balance.
    private static func actualValues(_ month: BudgetMonth, prefix: String) -> [String: OracleValue] {
        var fields: [String: Int] = [
            "to-budget": month.toBudget,
            "available-funds": month.incomeAvailable,
            "from-last-month": month.fromLastMonth,
            "buffered-selected": month.forNextMonth,
            "total-income": month.totalIncome,
            // Envelope's sheet negates `total-budgeted` (loot-core envelope.ts:150); tracking's does not (tracking.ts:97).
            "total-budgeted": month.trackingSummary == nil ? -month.totalBudgeted : month.totalBudgeted,
            "total-spent": month.totalSpent,
            "total-leftover": month.totalBalance,
            "last-month-overspent": month.lastMonthOverspent,
        ]
        if let tracking = month.trackingSummary {
            fields["total-budget-income"] = tracking.budgetedIncome
            fields["total-saved"] = tracking.plannedSavings
            fields["real-saved"] = tracking.actualSavings
        }
        var values: [String: OracleValue] = [:]
        for (field, value) in fields {
            values["\(prefix)\(month.month).\(field)"] = .number(Double(value))
        }
        for category in month.categoryGroups.flatMap(\.categories) {
            let key = "\(prefix)\(month.month).category.\(category.id)"
            values["\(key).budgeted"] = .number(Double(category.budgeted))
            values["\(key).spent"] = .number(Double(category.spent))
            values["\(key).leftover"] = .number(Double(category.balance))
            values["\(key).carryover"] = .number(category.carryover ? 1 : 0)
        }
        return values
    }

    private static func cellWrite(_ message: ActualSyncDecodedMessage) -> CellWrite {
        CellWrite(dataset: message.dataset, row: message.row, column: message.column, serialized: message.serializedValue)
    }

    // MARK: Fixture reads

    private static func cellWrites(_ step: [String: Any]) throws -> [CellWrite] {
        guard let cells = step["cells"], !(cells is NSNull) else {
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

    private static func integer(_ object: [String: Any], _ key: String) throws -> Int {
        guard let value = OracleJSON.int(object[key]) else {
            throw OracleReplayError.malformedFixture("\(key) is not an integer")
        }
        return value
    }

    /// A `YYYY-MM` or `YYYY-MM-DD` string as Actual's compact integer, such as 202608 or 20260801.
    private static func compactInteger(_ object: [String: Any], _ key: String) throws -> Int {
        let text = try OracleJSON.string(object, key).replacingOccurrences(of: "-", with: "")
        guard let value = Int(text) else {
            throw OracleReplayError.malformedFixture("\(key) is not a date or month")
        }
        return value
    }

    private static func boolean(_ object: [String: Any], _ key: String) throws -> Bool {
        guard let value = (object[key] as? NSNumber)?.boolValue else {
            throw OracleReplayError.malformedFixture("\(key) is not a boolean")
        }
        return value
    }

    private static func flag(_ object: [String: Any], _ key: String) -> Int {
        (object[key] as? NSNumber)?.boolValue == true ? 1 : 0
    }
}
