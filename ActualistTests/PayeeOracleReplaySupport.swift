import Foundation
import GRDB
@testable import Actualist

/// Replays the Payees oracle contract through the production store's payee commands (create, rename,
/// merge, delete, favorite and category learning, global category learning) on a starter-schema
/// budget seeded from the fixture's `world`. The compared and excluded parts are documented in
/// `scripts/payee-parity/README.md`. The recorded undo is not replayed here; a later undo oracle
/// owns it.
@MainActor
enum PayeeOracleReplay {
    private static let budgetID = "budget"

    /// Tables the world seeds. Starter rows are deleted from each (and from `preferences`) first, children before parents.
    private static let seedTables = [
        "accounts", "category_groups", "categories", "category_mapping", "payees", "payee_mapping",
        "rules", "schedules", "transactions",
    ]
    private static let clearedTables = [
        "transactions", "schedules_next_date", "schedules", "rules", "payee_mapping", "payees",
        "category_mapping", "categories", "category_groups", "accounts", "preferences",
    ]

    // MARK: Expected

    /// What Actual recorded for the case, in comparison form.
    static func expected(_ entry: [String: Any]) throws -> OracleValue {
        if try OracleJSON.string(entry, "kind") == "read" {
            let read = try OracleJSON.object(entry["read"], "read")
            guard let recorded = read["orphaned"] as? [String] else {
                throw OracleReplayError.malformedFixture("orphaned is not a list of ids")
            }
            let orphaned = recorded.sorted()
            return .object([
                "payees": try OracleValue(json: read["payeesGet"] ?? NSNull()),
                "ruleCounts": try OracleValue(json: read["ruleCounts"] ?? NSNull()),
                "orphaned": .array(orphaned.map(OracleValue.string)),
            ])
        }
        var fields: [String: OracleValue] = [
            "writes": OracleWriteReplay.sortedWrites(try OracleValue(json: entry["writes"] ?? NSNull())),
            "rows": OracleWriteReplay.sortedRows(try OracleValue(json: entry["rows"] ?? NSNull())),
        ]
        // An action Actual's UI never sends has no outcome to compare.
        if !(entry["handlerCall"] is NSNull) {
            fields["outcome"] = .string(entry["handlerError"] == nil ? "ok" : "refused")
        }
        return .object(fields)
    }

    // MARK: Replay

    static func replay(entry: [String: Any], world: [String: Any]) async throws -> OracleValue {
        let permit = await OracleReplayGate.shared.acquire()
        defer { permit.release() }
        let kind = try OracleJSON.string(entry, "kind")
        let input = try OracleJSON.object(entry["input"], "input")

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PayeeOracleReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "db.sqlite")
        let database = try await OracleReplayDatabase.starter(at: url, localNodeID: "node1")
        let preferences = try OracleJSON.objects(entry["preferencesSeed"] ?? [], "preferencesSeed")
        try await seed(database, world: world, preferences: preferences)

        if kind == "read" {
            return try await readSeed(database)
        }

        let store = LocalFirstActualStore(
            keychain: KeychainStore(service: UUID().uuidString, account: "token", backend: FakeKeychainBackend())
        )
        store.openedBudgetID = budgetID
        store.database = database
        var outcome = "ok"
        do {
            try await perform(kind: kind, input: input, call: entry["handlerCall"], store: store)
        } catch {
            outcome = "refused"
        }

        let messages = try await database.pendingLocalSyncMessages(limit: 100_000).map(\.message)
        let rows = try await readRows(database, includePreferences: kind == "global-learning")
        let seeded = seededIDs(world)
        let aliases = newIDAliases(messages: messages, rows: rows, seeded: seeded)

        var fields: [String: OracleValue] = [
            "writes": OracleWriteReplay.sortedWrites(OracleWriteReplay.aliased(OracleWriteReplay.netWrites(messages), aliases)),
            "rows": OracleWriteReplay.sortedRows(OracleWriteReplay.aliased(rows, aliases)),
        ]
        if !(entry["handlerCall"] is NSNull) {
            fields["outcome"] = .string(outcome)
        }
        return .object(fields)
    }

    /// The production call for the case. What Actual's UI picked (the target value of a
    /// favorite or learning toggle, the global value) is read from the recorded call, so the
    /// all-on-turns-off selection rule is Actual's and not recomputed here.
    private static func perform(
        kind: String,
        input: [String: Any],
        call: Any?,
        store: LocalFirstActualStore
    ) async throws {
        switch kind {
        case "create":
            try await store.createPayeeAndRefresh(budgetID: budgetID, name: try OracleJSON.string(input, "typed"))
        case "rename":
            try await store.renamePayeeAndRefresh(
                budgetID: budgetID,
                payeeID: try OracleJSON.string(input, "payeeID"),
                name: try OracleJSON.string(input, "typed")
            )
        case "merge":
            try await store.mergePayeesAndRefresh(
                budgetID: budgetID,
                sourcePayeeIDs: Set(input["mergeIDs"] as? [String] ?? []),
                targetPayeeID: try OracleJSON.string(input, "targetID")
            )
        case "delete":
            try await store.deletePayeesAndRefresh(budgetID: budgetID, payeeIDs: Set(input["payeeIDs"] as? [String] ?? []))
        case "toggle-single", "toggle-selection":
            let field = try OracleJSON.string(input, "field")
            let payload = try OracleJSON.object(OracleJSON.object(call, "handlerCall")["payload"], "payload")
            let updates = try OracleJSON.objects(payload["updated"], "updated").map { update in
                let id = try OracleJSON.string(update, "id")
                guard let value = update[field] as? Bool else {
                    throw OracleReplayError.malformedFixture("\(field) is not a Bool in the recorded call")
                }
                return field == "favorite"
                    ? PayeeManagementUpdate(payeeID: id, favorite: value)
                    : PayeeManagementUpdate(payeeID: id, learnCategories: value)
            }
            try await store.updatePayeesAndRefresh(budgetID: budgetID, updates: updates)
        case "global-learning":
            let payload = try OracleJSON.object(OracleJSON.object(call, "handlerCall")["payload"], "payload")
            try await store.setGlobalCategoryLearningAndRefresh(
                budgetID: budgetID,
                enabled: try OracleJSON.string(payload, "value") == "true"
            )
        default:
            throw OracleReplayError.malformedFixture("unknown case kind \(kind)")
        }
    }

    // MARK: Reads

    private static func readSeed(_ database: BudgetDatabase) async throws -> OracleValue {
        let snapshot = try await database.fetchPayeeManagementSnapshot()
        var counts: [String: OracleValue] = [:]
        for payee in snapshot.payees where payee.ruleReferenceCount > 0 {
            counts[payee.id] = .number(Double(payee.ruleReferenceCount))
        }
        let orphaned = snapshot.payees.filter { !$0.isTransfer && $0.isUnused }.map(\.id).sorted()
        return .object([
            "payees": .array(snapshot.payees.map { .object(["id": .string($0.id), "name": .string($0.displayName)]) }),
            "ruleCounts": .object(counts),
            "orphaned": .array(orphaned.map(OracleValue.string)),
        ])
    }

    private static func readRows(_ database: BudgetDatabase, includePreferences: Bool) async throws -> OracleValue {
        let queue = await database.queue
        return try await queue.read { db -> OracleValue in
            func table(_ sql: String) throws -> OracleValue {
                .array(try Row.fetchAll(db, sql: sql).map { row in
                    .object(Dictionary(uniqueKeysWithValues: row.columnNames.map { name in
                        (name, OracleValue.databaseValue(row[name]))
                    }))
                })
            }
            var rows: [String: OracleValue] = [
                "payees": try table(
                    "SELECT id, name, transfer_acct, favorite, learn_categories, tombstone FROM payees ORDER BY id"
                ),
                "payee_mapping": try table("SELECT id, targetId FROM payee_mapping ORDER BY id"),
            ]
            if includePreferences {
                rows["preferences"] = try table("SELECT id, value FROM preferences ORDER BY id")
            }
            return .object(rows)
        }
    }

    // MARK: Aliasing

    /// Ids the world seeds; an id outside it is one the action minted.
    private static func seededIDs(_ world: [String: Any]) -> Set<String> {
        var ids: Set<String> = []
        for table in ["payees", "payee_mapping"] {
            for row in (world[table] as? [[String: Any]]) ?? [] {
                if let id = row["id"] as? String { ids.insert(id) }
            }
        }
        return ids
    }

    /// Actual's minted ids are `uuid-N` by first appearance; the store mints UUIDs. Only payee ids are minted.
    private static func newIDAliases(
        messages: [ActualSyncDecodedMessage],
        rows: OracleValue,
        seeded: Set<String>
    ) -> [String: String] {
        var ordered: [String] = []
        func note(_ id: String) {
            if !seeded.contains(id), !ordered.contains(id) { ordered.append(id) }
        }
        for message in messages where message.dataset == "payees" || message.dataset == "payee_mapping" {
            note(message.row)
        }
        if case .array(let payees)? = rows.field("payees") {
            for payee in payees {
                if case .string(let id)? = payee.field("id") { note(id) }
            }
        }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, "uuid-\($0.offset + 1)") })
    }

    // MARK: Seeding

    private struct SeedRow: Sendable {
        let sql: String
        let values: [DatabaseValue]
    }

    private static func seed(
        _ database: BudgetDatabase,
        world: [String: Any],
        preferences: [[String: Any]]
    ) async throws {
        var rows: [SeedRow] = []
        for table in seedTables {
            for row in try OracleJSON.objects(world[table] ?? [], table) {
                let columns = row.keys.sorted()
                let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
                rows.append(SeedRow(
                    sql: "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))",
                    values: try columns.map { try OracleWriteReplay.seedValue(row[$0] ?? NSNull(), column: "\(table).\($0)") }
                ))
            }
        }
        let seededPreferences = try preferences.map {
            (id: try OracleJSON.string($0, "id"), value: try OracleJSON.string($0, "value"))
        }
        let insertions = rows
        let queue = await database.queue
        let cleared = clearedTables
        try await queue.write { db in
            for table in cleared {
                guard try db.tableExists(table) else { continue }
                try db.execute(sql: "DELETE FROM \(table)")
            }
            for row in insertions {
                try db.execute(sql: row.sql, arguments: StatementArguments(row.values as [any DatabaseValueConvertible]))
            }
            for preference in seededPreferences {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO preferences (id, value) VALUES (?, ?)",
                    arguments: [preference.id, preference.value]
                )
            }
        }
    }
}
