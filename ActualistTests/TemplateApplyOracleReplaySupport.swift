import Foundation
import GRDB
@testable import Actualist

/// Replays Apply Templates oracle cases through the production apply path that
/// `LocalFirstActualStore.applyBudgetTemplateAndRefresh` runs: the plan and its messages are
/// built inside one `commitUserActionPlan` write transaction, with the fixture's `currentMonth`
/// passed through the existing `budgetTemplateApply(currentMonth:)` parameter.
@MainActor
enum TemplateApplyOracleReplay {
    /// Input tables, parents before children. Each one is cleared of starter rows and refilled
    /// from the case's `input`, so starter categories never reach the result.
    private static let seedTables = [
        "accounts", "category_groups", "categories", "category_mapping", "payees",
        "rules", "schedules", "schedules_next_date", "transactions",
        "zero_budgets", "reflect_budgets", "zero_budget_months", "notes", "preferences",
    ]

    /// The persisted-row columns compared, in the order `persistedBudgets` lists them.
    private static let persistedColumns = ["id", "amount", "carryover", "category", "goal", "long_goal", "month"]

    /// The compared fields. `notification` and `error` are oracle outputs with no Actualist
    /// counterpart yet and are not compared.
    struct ReplayResult {
        let expected: OracleValue
        let actual: OracleValue
        /// CRDT messages the apply produced. Zero for a no-op. Not compared.
        let messageCount: Int
        /// The production refusal, if the plan threw. The state is still compared.
        let refusal: String?
    }

    /// One seeded row as SQL and values. Built before the write, so the write closure captures
    /// only Sendable data.
    private struct SeedRow: Sendable {
        let sql: String
        let values: [DatabaseValue]
    }

    /// A category whose stored definition is null while its live note carries a template directive
    /// and the oracle's definition is non-null. Production never regenerates that definition from
    /// the note at apply (OP-24).
    static func hasNoteOnlyTemplate(_ entry: [String: Any]) throws -> Bool {
        let input = try OracleJSON.object(entry["input"], "input")
        let expected = try OracleJSON.object(entry["expected"], "expected")
        var noteByID: [String: String] = [:]
        for note in try OracleJSON.objects(input["notes"], "notes") {
            if let id = note["id"] as? String {
                noteByID[id] = note["note"] as? String ?? ""
            }
        }
        let oracleIDs = Set(try definitionsByID(expected).keys)
        return try OracleJSON.objects(input["categories"], "categories").contains { category in
            guard OracleJSON.int(category["tombstone"]) == 0,
                  category["goal_def"] == nil || category["goal_def"] is NSNull,
                  let id = category["id"] as? String,
                  oracleIDs.contains(id),
                  let note = noteByID[id] else {
                return false
            }
            return note.contains("#template") || note.contains("#goal")
        }
    }

    /// Replays one case. `seedGoalDefsFromOracle` gives each note-only category the oracle's
    /// expected definition as its stored `goal_def`, so the apply engine runs on its own; see the
    /// README's "Two replays" section.
    static func replay(_ entry: [String: Any], currentMonth: String, seedGoalDefsFromOracle: Bool) async throws -> ReplayResult {
        let permit = await OracleReplayGate.shared.acquire()
        defer { permit.release() }
        let input = try OracleJSON.object(entry["input"], "input")
        let operation = try OracleJSON.object(entry["operation"], "operation")
        let expectedFields = try OracleJSON.object(entry["expected"], "expected")
        let month = try OracleJSON.string(operation, "month")
        let command: BudgetTemplateCommand = try OracleJSON.string(operation, "kind") == "overwrite"
            ? .overwrite
            : .fillEmpty
        let oracleDefinitions = seedGoalDefsFromOracle ? try definitionsByID(expectedFields) : [:]
        let monthValue = try BudgetDatabase.actualMonthValue(month)
        let rows = try seedRows(input: input, month: monthValue, oracleDefinitions: oracleDefinitions)
        let cleared = seedTables.filter { input[$0] != nil }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TemplateApplyOracleReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "db.sqlite")
        // The starter factory opens without a local node id; reopening with one sets the clock that apply writes need.
        let database = try await OracleReplayDatabase.starter(at: url, localNodeID: "node1")
        try await seed(database, rows: rows, clearing: cleared)

        let mode = try await database.requireBudgetMode(nil)
        var messageCount = 0
        var refusal: String?
        do {
            let applied = try await database.commitUserActionPlan(source: .ui, expectedMode: mode) { database, db in
                var builder = LocalFirstSyncMessageBuilder()
                let result = try database.budgetTemplateApply(
                    command: command,
                    month: month,
                    currentMonth: currentMonth,
                    db: db,
                    builder: &builder
                )
                return UserActionPlan(
                    drafts: result.messages,
                    descriptor: result.assignments.isEmpty
                        ? nil
                        : .template(month: month, mode: command.mode, assignments: result.assignments),
                    outcome: result
                )
            }
            messageCount = applied.outcome.messages.count
        } catch let error as LocalFirstError {
            refusal = String(describing: error)
        }

        var expected = try expectedValue(expectedFields, input: input)
        var actual = try await snapshot(database, month: month)
        if seedGoalDefsFromOracle {
            expected = removingTemplateSettings(expected)
            actual = removingTemplateSettings(actual)
        }
        return ReplayResult(
            expected: expected,
            actual: actual,
            messageCount: messageCount,
            refusal: refusal
        )
    }

    // MARK: Seeding

    private static func definitionsByID(_ expected: [String: Any]) throws -> [String: Any] {
        var definitions: [String: Any] = [:]
        for definition in try OracleJSON.objects(expected["goalDefinitions"], "goalDefinitions") {
            guard let id = definition["id"] as? String, let goalDef = definition["goalDef"], !(goalDef is NSNull) else {
                continue
            }
            definitions[id] = goalDef
        }
        return definitions
    }

    private static func seedRows(input: [String: Any], month: Int, oracleDefinitions: [String: Any]) throws -> [SeedRow] {
        var rows: [SeedRow] = []
        for table in seedTables {
            for var row in try OracleJSON.objects(input[table] ?? [], table) {
                if table == "categories", let id = row["id"] as? String, let definition = oracleDefinitions[id],
                   row["goal_def"] == nil || row["goal_def"] is NSNull {
                    let data = try JSONSerialization.data(withJSONObject: definition)
                    row["goal_def"] = String(decoding: data, as: UTF8.self)
                    // UI-managed categories are outside the note staleness guard, which is a separate
                    // note-parser comparison; this replay isolates the apply engine.
                    row["template_settings"] = "{\"source\":\"ui\"}"
                }
                let columns = row.keys.sorted()
                let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
                rows.append(SeedRow(
                    sql: "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))",
                    values: try columns.map { try databaseValue(row[$0] ?? NSNull(), column: "\(table).\($0)") }
                ))
            }
        }
        rows += try zeroBudgetRows(input: input, month: month)
        return rows
    }

    /// The oracle's harness creates a zero budget row for every live expense category when it loads
    /// the sheet (upstream `createAllBudgets`), before the apply runs. Seed the same rows for the
    /// operation month wherever the case supplies none, in the table its `budgetType` preference names.
    private static func zeroBudgetRows(input: [String: Any], month: Int) throws -> [SeedRow] {
        let tracking = try OracleJSON.objects(input["preferences"] ?? [], "preferences").contains {
            $0["id"] as? String == "budgetType" && $0["value"] as? String == "tracking"
        }
        let table = tracking ? "reflect_budgets" : "zero_budgets"
        let supplied = Set(try OracleJSON.objects(input[table] ?? [], table).compactMap { row in
            OracleJSON.int(row["month"]) == month ? row["category"] as? String : nil
        })
        let expenseCategories = try OracleJSON.objects(input["categories"] ?? [], "categories").compactMap { category -> String? in
            guard OracleJSON.int(category["tombstone"]) == 0,
                  OracleJSON.int(category["is_income"]) == 0,
                  let id = category["id"] as? String else {
                return nil
            }
            return id
        }
        return expenseCategories.filter { !supplied.contains($0) }.map { category in
            SeedRow(
                sql: "INSERT INTO \(table) (id, amount, carryover, category, goal, long_goal, month) VALUES (?, 0, 0, ?, NULL, NULL, ?)",
                values: ["\(month)-\(category)".databaseValue, category.databaseValue, month.databaseValue]
            )
        }
    }

    /// Removes `templateSettings` from each goal definition. Test B seeds some categories as UI-managed
    /// (see `seedRows`), so that field is not compared there; Test A compares it.
    private static func removingTemplateSettings(_ value: OracleValue) -> OracleValue {
        guard case .object(var fields) = value, case .array(let definitions)? = fields["goalDefinitions"] else {
            return value
        }
        fields["goalDefinitions"] = .array(definitions.map { definition in
            guard case .object(var entry) = definition else {
                return definition
            }
            entry.removeValue(forKey: "templateSettings")
            return .object(entry)
        })
        return .object(fields)
    }

    private static func seed(_ database: BudgetDatabase, rows: [SeedRow], clearing: [String]) async throws {
        let queue = await database.queue
        try await queue.write { db in
            for table in clearing.reversed() {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            for row in rows {
                try db.execute(sql: row.sql, arguments: StatementArguments(row.values as [any DatabaseValueConvertible]))
            }
        }
    }

    nonisolated private static func databaseValue(_ value: Any, column: String) throws -> DatabaseValue {
        switch value {
        case is NSNull:
            return .null
        case let text as String:
            return text.databaseValue
        case let number as NSNumber:
            let integer = number.int64Value
            return Double(integer) == number.doubleValue ? integer.databaseValue : number.doubleValue.databaseValue
        default:
            throw OracleReplayError.malformedFixture("\(column) is not a scalar value")
        }
    }

    // MARK: Reading

    /// The compared fields after the apply, read through production reads where one exists.
    /// Balance is To Budget for envelope budgets and planned savings for tracking budgets, the same
    /// value `trackingTotalSaved` returns. Goal fields and persisted rows come from the stored budget
    /// table, which the category read model does not carry.
    private static func snapshot(_ database: BudgetDatabase, month: String) async throws -> OracleValue {
        let monthValue = try BudgetDatabase.actualMonthValue(month)
        let budgetMonth = try await database.fetchBudgetMonth(month: month)
        let table = budgetMonth.trackingSummary == nil ? BudgetTable.envelope : .tracking
        let balance = budgetMonth.trackingSummary?.plannedSavings ?? budgetMonth.toBudget
        let queue = await database.queue
        let columns = persistedColumns

        let storedRows: [[String: OracleValue]] = try await queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, amount, carryover, category, goal, long_goal, month
                    FROM \(table.rawValue)
                    WHERE month = ?
                    """,
                arguments: [monthValue]
            ).map { row in
                Dictionary(uniqueKeysWithValues: columns.map { ($0, OracleValue.databaseValue(row[$0])) })
            }
        }

        let categories: [OracleValue] = budgetMonth.categoryGroups
            .filter { !$0.isIncome }
            .flatMap(\.categories)
            .map { category in
                let stored = storedRows.first { $0["category"] == OracleValue.string(category.id) }
                return .object([
                    "id": .string(category.id),
                    "budget": .number(Double(category.budgeted)),
                    "goal": stored?["goal"] ?? .null,
                    "longGoal": stored?["long_goal"] ?? .null,
                ])
            }

        let goalDefinitions: [OracleValue] = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, goal_def, template_settings FROM categories ORDER BY id").map { row in
                OracleValue.object([
                    "id": OracleValue.databaseValue(row["id"]),
                    "goalDef": try parsedJSON(row["goal_def"]),
                    "templateSettings": try parsedJSON(row["template_settings"]),
                ])
            }
        }

        return .object([
            "balance": .number(Double(balance)),
            "categories": .array(categories),
            "persistedBudgets": .array(storedRows.map { .object($0) }),
            "goalDefinitions": .array(goalDefinitions),
        ])
    }

    nonisolated private static func parsedJSON(_ value: DatabaseValue) throws -> OracleValue {
        guard let text = String.fromDatabaseValue(value) else {
            return .null
        }
        return try OracleValue(json: JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]))
    }

    // MARK: Expected

    /// The oracle's fields in the same shape as `snapshot`. Its sheet names each category `category`,
    /// so it is renamed to `id`. A deleted category is not on the budget sheet, so its budget cells
    /// are left out of `categories`; its goal definition is still compared in `goalDefinitions`.
    private static func expectedValue(_ expected: [String: Any], input: [String: Any]) throws -> OracleValue {
        let deleted = Set(try OracleJSON.objects(input["categories"], "categories").compactMap { category in
            OracleJSON.int(category["tombstone"]) == 1 ? category["id"] as? String : nil
        })
        let categories = try OracleJSON.objects(expected["categories"], "categories").compactMap { category -> OracleValue? in
            guard let id = category["category"] as? String, !deleted.contains(id) else {
                return nil
            }
            var renamed = category
            renamed.removeValue(forKey: "category")
            renamed["id"] = id
            return try OracleValue(json: renamed)
        }
        return .object([
            "balance": try OracleValue(json: expected["balance"] ?? NSNull()),
            "categories": .array(categories),
            "persistedBudgets": try OracleValue(json: expected["persistedBudgets"] ?? []),
            "goalDefinitions": try OracleValue(json: expected["goalDefinitions"] ?? []),
        ])
    }
}
