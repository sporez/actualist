import Foundation
import GRDB
@testable import Actualist

/// Replays the AccountGroups oracle contract through the production store's account group commands
/// (create, rename, move, delete, assign an account) and its two reads (the group list and the
/// Accounts screen's grouped sections), on a starter-schema budget seeded from the fixture's `world`.
/// The compared and excluded parts are documented in `scripts/account-group-parity/README.md`. The
/// recorded undo is not replayed here.
@MainActor
enum AccountGroupOracleReplay {
    private static let budgetID = "budget"

    /// Tables the world seeds, parents before children.
    private static let seedTables = ["account_groups", "accounts"]
    /// Cleared before seeding, children before parents.
    private static let clearedTables = [
        "transactions", "schedules_next_date", "schedules", "rules", "payee_mapping", "payees",
        "zero_budgets", "reflect_budgets", "zero_budget_months", "reflect_budget_months",
        "category_mapping", "categories", "category_groups", "accounts", "account_groups", "preferences",
    ]

    // MARK: Expected

    /// What Actual recorded for the case, in comparison form.
    static func expected(_ entry: [String: Any]) throws -> OracleValue {
        let kind = try OracleJSON.string(entry, "kind")
        if kind.hasPrefix("read-") {
            var read = try OracleJSON.object(entry["read"], "read")
            // Actual's closed accounts are one flat list: one ungrouped bucket, in Actual's order.
            if let closed = read["closed"] as? [String] {
                read["closed"] = [["groupId": NSNull(), "accountIds": closed] as [String: Any]]
            }
            return try OracleValue(json: read)
        }
        var fields: [String: OracleValue] = [
            "writes": OracleWriteReplay.sortedWrites(try OracleValue(json: entry["writes"] ?? NSNull())),
            "rows": OracleWriteReplay.sortedRows(try OracleValue(json: entry["rows"] ?? NSNull())),
            "order": try OracleValue(json: entry["order"] ?? NSNull()),
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
            .appending(path: "AccountGroupOracleReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "db.sqlite")
        let database = try await OracleReplayDatabase.starter(at: url, localNodeID: "node1")
        try await seed(database, world: world)

        let store = LocalFirstActualStore(
            keychain: KeychainStore(service: UUID().uuidString, account: "token", backend: FakeKeychainBackend())
        )
        store.openedBudgetID = budgetID
        store.database = database

        if kind.hasPrefix("read-") {
            return try await read(kind: kind, store: store)
        }

        var outcome = "ok"
        do {
            try await perform(kind: kind, input: input, call: entry["handlerCall"], store: store)
        } catch {
            outcome = "refused"
        }
        try await store.refreshAccountsWithBalances(budgetID: budgetID)

        let messages = try await database.pendingLocalSyncMessages(limit: 100_000).map(\.message)
        let rows = try await readRows(database)
        let aliases = newIDAliases(messages: messages, rows: rows, seeded: seededIDs(world))
        var fields: [String: OracleValue] = [
            "writes": OracleWriteReplay.sortedWrites(OracleWriteReplay.aliased(OracleWriteReplay.netWrites(messages), aliases)),
            "rows": OracleWriteReplay.sortedRows(OracleWriteReplay.aliased(rows, aliases)),
            "order": OracleWriteReplay.aliased(.array(store.accountGroups(budgetID: budgetID).map { .string($0.id) }), aliases),
        ]
        if !(entry["handlerCall"] is NSNull) {
            fields["outcome"] = .string(outcome)
        }
        return .object(fields)
    }

    /// The production call for the case. The typed text goes through as typed; the move target is the
    /// `targetId` Actual's UI sent.
    private static func perform(
        kind: String,
        input: [String: Any],
        call: Any?,
        store: LocalFirstActualStore
    ) async throws {
        switch kind {
        case "group-create":
            try await store.createAccountGroupAndRefresh(budgetID: budgetID, name: try OracleJSON.string(input, "typed"))
        case "group-rename":
            try await store.renameAccountGroupAndRefresh(
                budgetID: budgetID,
                groupID: try OracleJSON.string(input, "groupID"),
                name: try OracleJSON.string(input, "typed")
            )
        case "group-move":
            let payload = try OracleJSON.object(OracleJSON.object(call, "handlerCall")["payload"], "payload")
            try await store.moveAccountGroupAndRefresh(
                budgetID: budgetID,
                groupID: try OracleJSON.string(input, "groupID"),
                beforeGroupID: payload["targetId"] as? String
            )
        case "group-delete":
            try await store.deleteAccountGroupAndRefresh(budgetID: budgetID, groupID: try OracleJSON.string(input, "groupID"))
        case "account-assign":
            try await store.moveAccountToGroupAndRefresh(
                budgetID: budgetID,
                accountID: try OracleJSON.string(input, "accountID"),
                groupID: input["groupID"] as? String
            )
        default:
            throw OracleReplayError.malformedFixture("unknown case kind \(kind)")
        }
    }

    // MARK: Reads

    private static func read(kind: String, store: LocalFirstActualStore) async throws -> OracleValue {
        try await store.refreshAccountsWithBalances(budgetID: budgetID)
        switch kind {
        case "read-groups":
            return .object(["groups": .array(store.accountGroups(budgetID: budgetID).map { group in
                .object([
                    "id": .string(group.id),
                    "name": .string(group.name),
                    "sort_order": .number(group.sortOrder),
                ])
            })])
        case "read-tree":
            // The sections the Accounts screen renders (AccountsViewModel.sections over the store's
            // cached displays and groups, no saved account order), each section's buckets as they are.
            let sections = AccountListLayout.sections(
                displays: store.accountDisplays(budgetID: budgetID),
                groups: store.accountGroups(budgetID: budgetID),
                preferredIDs: []
            )
            func buckets(_ kind: AccountListLayout.Kind) -> OracleValue {
                let section = sections.first { $0.kind == kind }
                return .array((section?.buckets ?? []).map { bucket in
                    .object([
                        "groupId": bucket.group.map { .string($0.id) } ?? .null,
                        "accountIds": .array(bucket.accounts.map { .string($0.id) }),
                    ])
                })
            }
            return .object([
                "onBudget": buckets(.budget),
                "offBudget": buckets(.offBudget),
                "closed": buckets(.closed),
            ])
        default:
            throw OracleReplayError.malformedFixture("unknown read \(kind)")
        }
    }

    private static func readRows(_ database: BudgetDatabase) async throws -> OracleValue {
        let queue = await database.queue
        return try await queue.read { db -> OracleValue in
            func table(_ sql: String) throws -> OracleValue {
                .array(try Row.fetchAll(db, sql: sql).map { row in
                    .object(Dictionary(uniqueKeysWithValues: row.columnNames.map { name in
                        (name, OracleValue.databaseValue(row[name]))
                    }))
                })
            }
            return .object([
                "account_groups": try table("SELECT id, name, sort_order, tombstone FROM account_groups ORDER BY id"),
                "accounts": try table(
                    "SELECT id, name, account_group_id, sort_order, offbudget, closed, tombstone FROM accounts ORDER BY id"
                ),
            ])
        }
    }

    // MARK: Aliasing

    private static func seededIDs(_ world: [String: Any]) -> Set<String> {
        var ids: Set<String> = []
        for table in seedTables {
            for row in (world[table] as? [[String: Any]]) ?? [] {
                if let id = row["id"] as? String { ids.insert(id) }
            }
        }
        return ids
    }

    /// Actual's minted ids are `uuid-N` by first appearance; the store mints UUIDs. Only group ids are minted.
    private static func newIDAliases(
        messages: [ActualSyncDecodedMessage],
        rows: OracleValue,
        seeded: Set<String>
    ) -> [String: String] {
        var ordered: [String] = []
        func note(_ id: String) {
            if !seeded.contains(id), !ordered.contains(id) { ordered.append(id) }
        }
        for message in messages where message.dataset == "account_groups" {
            note(message.row)
        }
        if case .array(let items)? = rows.field("account_groups") {
            for item in items {
                if case .string(let id)? = item.field("id") { note(id) }
            }
        }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, "uuid-\($0.offset + 1)") })
    }

    // MARK: Seeding

    private struct SeedRow: Sendable {
        let sql: String
        let values: [DatabaseValue]
    }

    private static func insertion(_ table: String, _ row: [String: Any]) throws -> SeedRow {
        let columns = row.keys.sorted()
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        return SeedRow(
            sql: "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))",
            values: try columns.map { try OracleWriteReplay.seedValue(row[$0] ?? NSNull(), column: "\(table).\($0)") }
        )
    }

    private static func seed(_ database: BudgetDatabase, world: [String: Any]) async throws {
        var rows: [SeedRow] = []
        for table in seedTables {
            for row in try OracleJSON.objects(world[table] ?? [], table) {
                rows.append(try insertion(table, row))
            }
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
        }
    }
}
