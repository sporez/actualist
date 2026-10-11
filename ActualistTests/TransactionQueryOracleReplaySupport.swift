import Foundation
import GRDB
@testable import Actualist

/// Replays the Transaction Query oracle (Q1 conditions, Q2 saved-filter creation, Q3 split families and
/// the split modes) through the production query and saved-filter paths on a starter-schema budget
/// seeded from the fixture world.
///
/// Conditions go the way a stored saved filter does: the fixture condition becomes the stored JSON,
/// `SavedTransactionFilter.project` turns it into structured query conditions, and
/// `fetchTransactionQueryPage` runs them over every account. Compared per condition or search case:
/// the individually matching ids (`splits: all` in Actual), the grouped roots, the displayed ids and the
/// attached context ids. Compared per condition case: the saved filter created from it (outcome, stored
/// row, the name, conditions and join cells written). Q2 cases compare the outcome class (created,
/// duplicate name, duplicate conditions), the stored rows and the cells written. Split-mode cases run
/// `fetchTransactionPage` in all, inline, none and grouped mode, with each family's children and
/// unmatched ids, and the account balance where the fixture records it.
///
/// Not compared: Actual's compiled AQL filters (no Actualist counterpart), the refusal text, the order
/// of written cells and the clock, and the `tombstone` cell Actualist also writes on create (the stored
/// row is compared, including `tombstone`). Unmatched ids are compared to the attached context ids and,
/// in the split-mode cases, to the family rows that the `all` read did not match.
@MainActor
enum TransactionQueryOracleReplay {
    private struct Session {
        let database: BudgetDatabase
        let queue: DatabaseQueue
    }

    private static let worldTables = [
        "accounts", "payees", "payee_mapping", "category_groups", "categories", "category_mapping", "transactions",
    ]

    private static let filterID = "uuid-1"

    // MARK: - Condition and family cases

    static func expectedQuery(_ entry: [String: Any]) throws -> OracleValue {
        let physical = try OracleJSON.object(entry["physical"], "physical")
        let grouped = try OracleJSON.object(entry["grouped"], "grouped")
        var fields = try queryFields(
            physical: strings(physical["ids"]),
            roots: strings(grouped["rootIDs"]),
            displayed: strings(grouped["displayedIDs"]),
            context: strings(grouped["contextIDs"]),
            unmatched: strings(grouped["unmatchedIDs"])
        )
        if let filter = entry["filter"] as? [String: Any] {
            fields["filter"] = try expectedFilter(filter)
        }
        return .object(fields)
    }

    static func replayQuery(_ entry: [String: Any], world: [String: Any], makeDirectory: () throws -> URL) async throws -> OracleValue {
        let session = try open(world: world, filters: [], directory: makeDirectory())
        let query: TransactionFeedQuery
        var filterRun: (conditions: [RuleCondition], join: RuleConditionJoin)?
        if let search = entry["search"] as? String {
            query = TransactionFeedQuery(text: search)
        } else {
            let condition = try OracleJSON.object(entry["condition"], "condition")
            let joinName = try OracleJSON.string(entry, "conditionsOp")
            let raw = try rawConditions([condition])
            let projected = SavedTransactionFilter.project(
                id: "replay", name: "replay", rawConditionsJSON: raw, conditionsOperation: joinName, tombstone: false
            )
            guard projected.isSupported, let conditions = projected.queryConditions, let join = projected.queryJoin else {
                return .object(["unsupported": .string(String(describing: projected.compatibility))])
            }
            query = TransactionFeedQuery(conditionsJoin: join, conditions: conditions)
            filterRun = (try decodeConditions(raw), RuleConditionJoin(rawValue: joinName) ?? .and)
        }

        let page = try await session.database.fetchTransactionQueryPage(scope: .spending, query: query)
        let roots = page.transactions.compactMap(\.id)
        let displayed = page.transactions.flatMap { [$0] + $0.subtransactions }.compactMap(\.id)
        var fields = queryFields(
            physical: Array(page.matchingTransactionIDs),
            roots: roots,
            displayed: displayed,
            context: Array(page.attachedContextTransactionIDs),
            unmatched: Array(page.attachedContextTransactionIDs)
        )
        if entry["filter"] != nil, let filterRun {
            let name = try OracleJSON.string(entry, "id")
            fields["filter"] = try await createFilter(
                name: name, conditions: filterRun.conditions, join: filterRun.join, seeded: [], makeDirectory: makeDirectory
            )
        }
        return .object(fields)
    }

    private static func queryFields(
        physical: [String],
        roots: [String],
        displayed: [String],
        context: [String],
        unmatched: [String]
    ) -> [String: OracleValue] {
        [
            "physical": sortedIDs(physical),
            "rootIDs": sortedIDs(roots),
            "displayedIDs": sortedIDs(displayed),
            "contextIDs": sortedIDs(context),
            "unmatchedIDs": sortedIDs(unmatched),
        ]
    }

    // MARK: - Saved filters

    static func expectedFilterCase(_ entry: [String: Any]) throws -> OracleValue {
        try expectedFilter(OracleJSON.object(entry["filter"], "filter"))
    }

    static func replayFilterCase(_ entry: [String: Any], makeDirectory: () throws -> URL) async throws -> OracleValue {
        let candidate = try OracleJSON.object(entry["candidate"], "candidate")
        let seeded = try OracleJSON.objects(entry["seededFilters"], "seededFilters")
        let conditions = try decodeConditions(rawConditions(OracleJSON.objects(candidate["conditions"], "conditions")))
        return try await createFilter(
            name: OracleJSON.string(candidate, "name"),
            conditions: conditions,
            join: RuleConditionJoin(rawValue: OracleJSON.string(candidate, "conditionsOp")) ?? .and,
            seeded: seeded,
            makeDirectory: makeDirectory
        )
    }

    private static func expectedFilter(_ filter: [String: Any]) throws -> OracleValue {
        let rows = try OracleJSON.objects(filter["rows"], "rows").map { row -> OracleValue in
            try OracleValue.object([
                "id": OracleValue(json: row["id"] ?? NSNull()),
                "name": OracleValue(json: row["name"] ?? NSNull()),
                "conditions": OracleValue(json: row["conditions"] ?? NSNull()),
                "conditionsOp": OracleValue(json: row["conditionsOp"] ?? NSNull()),
                "tombstone": OracleValue(json: row["tombstone"] ?? NSNull()),
            ])
        }
        let messages = try OracleJSON.objects(filter["messages"], "messages").map { message -> OracleValue in
            .object([
                "dataset": .string(try OracleJSON.string(message, "dataset")),
                "row": .string(try OracleJSON.string(message, "row")),
                "column": .string(try OracleJSON.string(message, "column")),
                "value": try messageValue(column: OracleJSON.string(message, "column"), text: OracleJSON.string(message, "value")),
            ])
        }
        return .object([
            "outcome": .string(try OracleJSON.string(filter, "outcome")),
            "rows": OracleValue.array(rows).sortedByID,
            "messages": sortedByColumn(messages),
        ])
    }

    private static func createFilter(
        name: String,
        conditions: [RuleCondition],
        join: RuleConditionJoin,
        seeded: [[String: Any]],
        makeDirectory: () throws -> URL
    ) async throws -> OracleValue {
        let session = try open(world: [:], filters: seeded, directory: makeDirectory())
        let before = Set(try await session.database.pendingLocalSyncMessages().map(\.message.timestamp))
        var builder = LocalFirstSyncMessageBuilder()
        let outcome: String
        do {
            _ = try await session.database.createSavedTransactionFilter(
                id: filterID,
                draft: SavedTransactionFilterDraft(name: name, conditions: conditions, join: join),
                builder: &builder
            )
            outcome = "created"
        } catch {
            let text = error.localizedDescription
            if text.contains("already a saved filter named") {
                outcome = "duplicate-name"
            } else if text.contains("already saved as") {
                outcome = "duplicate-condition"
            } else {
                outcome = "error: \(text)"
            }
        }

        let rows = try session.queue.readSync { db in
            try Row.fetchAll(db, sql: "SELECT id, name, conditions, conditions_op, tombstone FROM transaction_filters")
                .map { row -> OracleValue in
                    let raw: String? = row["conditions"]
                    let parsed = try raw.map { try OracleValue(json: JSONSerialization.jsonObject(with: Data($0.utf8))) } ?? .null
                    return .object([
                        "id": OracleValue.databaseValue(row["id"]),
                        "name": OracleValue.databaseValue(row["name"]),
                        "conditions": parsed,
                        "conditionsOp": OracleValue.databaseValue(row["conditions_op"]),
                        "tombstone": OracleValue.databaseValue(row["tombstone"]),
                    ])
                }
        }
        let messages = try await session.database.pendingLocalSyncMessages()
            .map(\.message)
            .filter { !before.contains($0.timestamp) && $0.column != "tombstone" }
            .map { message -> OracleValue in
                let text = message.serializedValue.hasPrefix("S:") ? String(message.serializedValue.dropFirst(2)) : message.serializedValue
                return .object([
                    "dataset": .string(message.dataset),
                    "row": .string(message.row),
                    "column": .string(message.column),
                    "value": try messageValue(column: message.column, text: text),
                ])
            }
        return .object([
            "outcome": .string(outcome),
            "rows": OracleValue.array(rows).sortedByID,
            "messages": sortedByColumn(messages),
        ])
    }

    /// The `conditions` cell is JSON text; the others are plain strings. Compared by parsed content so
    /// key order never decides a result.
    private static func messageValue(column: String, text: String) throws -> OracleValue {
        guard column == "conditions" else {
            return .string(text)
        }
        return try OracleValue(json: JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    private static func sortedByColumn(_ messages: [OracleValue]) -> OracleValue {
        .array(messages.sorted { $0.canonical < $1.canonical })
    }

    // MARK: - Split modes

    static func expectedSplitModes(_ entry: [String: Any]) throws -> OracleValue {
        var fields: [String: OracleValue] = ["results": try OracleValue(json: entry["results"] ?? NSNull())]
        if let balances = entry["balances"] {
            fields["balances"] = try OracleValue(json: balances)
        }
        return .object(fields)
    }

    static func replaySplitModes(_ entry: [String: Any], world: [String: Any], makeDirectory: () throws -> URL) async throws -> OracleValue {
        let session = try open(world: world, filters: [], directory: makeDirectory())
        let account = entry["account"] as? String
        let search = entry["search"] as? String
        func ids(_ result: BudgetDatabase.TransactionFetchResult) -> [OracleValue] {
            result.transactions.compactMap(\.id).map(OracleValue.string)
        }
        let all = try await session.database.fetchTransactionPage(accountID: account, matching: search, splits: .all)
        let inline = try await session.database.fetchTransactionPage(accountID: account, matching: search, splits: .inline)
        let none = try await session.database.fetchTransactionPage(
            accountID: account, matching: search, splits: TransactionSplitQueryMode.none
        )
        let grouped = try await session.database.fetchTransactionPage(accountID: account, matching: search, splits: .grouped)
        let matched = Set(all.transactions.compactMap(\.id))
        let families = grouped.transactions.map { root -> OracleValue in
            let children = root.subtransactions.compactMap(\.id)
            let unmatched = search == nil ? [] : ([root.id].compactMap { $0 } + children).filter { !matched.contains($0) }
            return .object([
                "id": .string(root.id ?? ""),
                "childIDs": .array(children.map(OracleValue.string)),
                "unmatchedIDs": .array(unmatched.map(OracleValue.string)),
            ])
        }
        var fields: [String: OracleValue] = [
            "results": .object([
                "all": .object(["ids": .array(ids(all))]),
                "inline": .object(["ids": .array(ids(inline))]),
                "none": .object(["ids": .array(ids(none))]),
                "grouped": .object(["ids": .array(ids(grouped)), "families": .array(families)]),
            ]),
        ]
        if let expected = entry["balances"] as? [String: Any] {
            let balances = try await session.database.accountBalances()
            fields["balances"] = .object(Dictionary(uniqueKeysWithValues: expected.keys.map {
                ($0, OracleValue.number(Double(balances[$0] ?? 0)))
            }))
        }
        return .object(fields)
    }

    // MARK: - Helpers

    private static func strings(_ value: Any?) throws -> [String] {
        guard let list = value as? [String] else {
            throw OracleReplayError.malformedFixture("expected an array of strings")
        }
        return list
    }

    private static func sortedIDs(_ ids: [String]) -> OracleValue {
        .array(ids.sorted().map(OracleValue.string))
    }

    private static func rawConditions(_ conditions: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: conditions, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeConditions(_ raw: String) throws -> [RuleCondition] {
        try JSONDecoder().decode([RuleCondition].self, from: Data(raw.utf8))
    }

    // MARK: - Seeding

    private static func open(world: [String: Any], filters: [[String: Any]], directory: URL) throws -> Session {
        let url = directory.appending(path: "db.sqlite")
        _ = try BudgetDatabase.makeNewBudgetStarterDatabase(at: url)
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            for table in ["transactions", "rules", "schedules", "payee_mapping", "payees",
                          "category_mapping", "categories", "category_groups", "accounts", "transaction_filters"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            for table in worldTables {
                for row in try OracleJSON.objects(world[table] ?? [], table) {
                    try insert(row, into: table, db: db)
                }
            }
            for filter in filters {
                var row = filter
                row["conditions"] = try rawConditions(OracleJSON.objects(filter["conditions"], "conditions"))
                row["conditions_op"] = row.removeValue(forKey: "conditionsOp")
                try insert(row, into: "transaction_filters", db: db)
            }
        }
        return Session(database: try BudgetDatabase(databaseURL: url, localNodeID: "node1"), queue: queue)
    }

    private static func insert(_ row: [String: Any], into table: String, db: Database) throws {
        let keys = row.keys.sorted()
        let marks = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        try db.execute(
            sql: "INSERT INTO \(table) (\(keys.joined(separator: ", "))) VALUES (\(marks))",
            arguments: StatementArguments(keys.map { databaseValue(row[$0]) })
        )
    }

    private static func databaseValue(_ value: Any?) -> DatabaseValue {
        switch value {
        case let text as String:
            return text.databaseValue
        case let number as NSNumber:
            return CFNumberIsFloatType(number)
                ? number.doubleValue.databaseValue
                : number.int64Value.databaseValue
        default:
            return .null
        }
    }
}
