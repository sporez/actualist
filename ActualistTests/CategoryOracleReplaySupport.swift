import Foundation
import GRDB
@testable import Actualist

/// Replays the Categories oracle contract through the production store's category and group commands
/// (create, rename, hide, move through `BudgetCategoryOutlineDraft`, delete with transfer) and its reads,
/// on a starter-schema budget seeded from the fixture's `world`. The compared and excluded parts are
/// documented in `scripts/category-parity/README.md`. The recorded undo is not replayed here.
@MainActor
enum CategoryOracleReplay {
    private static let budgetID = "budget"
    private static let month = "2026-09"

    /// Tables the world seeds, parents before children.
    private static let seedTables = [
        "accounts", "category_groups", "categories", "category_mapping",
        "zero_budgets", "zero_budget_months", "transactions",
    ]
    /// Cleared before seeding, children before parents; `preferences` returns the budget to its envelope default.
    private static let clearedTables = [
        "transactions", "schedules_next_date", "schedules", "rules", "payee_mapping", "payees",
        "zero_budgets", "reflect_budgets", "zero_budget_months", "reflect_budget_months",
        "category_mapping", "categories", "category_groups", "accounts", "preferences",
    ]

    // MARK: Expected

    /// What Actual recorded for the case, in comparison form.
    static func expected(_ entry: [String: Any]) throws -> OracleValue {
        let kind = try OracleJSON.string(entry, "kind")
        if kind.hasPrefix("read-") {
            let read = try OracleJSON.object(entry["read"], "read")
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
        if let mustTransfer = entry["mustTransfer"] {
            fields["actualistNeedsTransfer"] = try OracleValue(json: mustTransfer)
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
            .appending(path: "CategoryOracleReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "db.sqlite")
        let database = try await OracleReplayDatabase.starter(at: url, localNodeID: "node1")
        try await seed(database, world: world, stateRows: entry["stateRows"] as? [String: Any] ?? [:])

        let store = LocalFirstActualStore(
            keychain: KeychainStore(service: UUID().uuidString, account: "token", backend: FakeKeychainBackend())
        )
        store.openedBudgetID = budgetID
        store.database = database

        if kind.hasPrefix("read-") {
            return try await read(kind: kind, input: input, world: world, store: store, database: database)
        }

        var outcome = "ok"
        var actualistNeedsTransfer: OracleValue?
        do {
            actualistNeedsTransfer = try await perform(
                kind: kind, input: input, call: entry["handlerCall"], store: store
            )
        } catch {
            outcome = "refused"
        }

        let messages = try await database.pendingLocalSyncMessages(limit: 100_000).map(\.message)
        let rows = try await readRows(database)
        let aliases = newIDAliases(messages: messages, rows: rows, seeded: seededIDs(world))

        var fields: [String: OracleValue] = [
            "writes": OracleWriteReplay.sortedWrites(OracleWriteReplay.aliased(OracleWriteReplay.netWrites(messages), aliases)),
            "rows": OracleWriteReplay.sortedRows(OracleWriteReplay.aliased(rows, aliases)),
            "order": OracleWriteReplay.aliased(await outline(store: store, order: true), aliases),
        ]
        if !(entry["handlerCall"] is NSNull) {
            fields["outcome"] = .string(outcome)
        }
        if let actualistNeedsTransfer {
            fields["actualistNeedsTransfer"] = actualistNeedsTransfer
        }
        return .object(fields)
    }

    /// The production call for the case. What Actual's UI picked (a hide flag, a delete transfer) is read
    /// from the recorded call. Returns Actualist's own transfer decision for the two delete kinds.
    private static func perform(
        kind: String,
        input: [String: Any],
        call: Any?,
        store: LocalFirstActualStore
    ) async throws -> OracleValue? {
        func payload() throws -> [String: Any] {
            try OracleJSON.object(OracleJSON.object(call, "handlerCall")["payload"], "payload")
        }
        switch kind {
        case "category-create":
            _ = try await store.createCategoryAndRefresh(
                name: try OracleJSON.string(input, "typed"),
                groupID: try OracleJSON.string(input, "groupID"),
                budgetID: budgetID, month: month
            )
        case "group-create":
            _ = try await store.createCategoryGroupAndRefresh(
                name: try OracleJSON.string(input, "typed"), budgetID: budgetID, month: month
            )
        case "category-rename":
            _ = try await store.renameCategoryAndRefresh(
                categoryID: try OracleJSON.string(input, "categoryID"),
                name: try OracleJSON.string(input, "typed"),
                budgetID: budgetID, month: month
            )
        case "group-rename":
            _ = try await store.renameCategoryGroupAndRefresh(
                groupID: try OracleJSON.string(input, "groupID"),
                name: try OracleJSON.string(input, "typed"),
                budgetID: budgetID, month: month
            )
        case "category-hide":
            _ = try await store.setCategoryHiddenAndRefresh(
                categoryID: try OracleJSON.string(input, "categoryID"),
                hidden: try payload()["hidden"] as? Bool ?? false,
                budgetID: budgetID, month: month, didUpdate: {}
            )
        case "group-hide":
            _ = try await store.setCategoryGroupHiddenAndRefresh(
                groupID: try OracleJSON.string(input, "groupID"),
                hidden: try payload()["hidden"] as? Bool ?? false,
                budgetID: budgetID, month: month, didUpdate: {}
            )
        case "category-move":
            // The Budget screen builds the draft from the month's category groups
            // (BudgetCategoryReorderWorkflow.begin) and saves draft.command through the repository.
            var draft = try await outlineDraft(store: store)
            try draft.moveCategory(
                id: try OracleJSON.string(input, "categoryID"),
                toGroupID: try OracleJSON.string(input, "groupID"),
                beforeCategoryID: input["targetID"] as? String
            )
            try await save(draft, store: store)
        case "group-move":
            var draft = try await outlineDraft(store: store)
            try draft.moveGroup(
                id: try OracleJSON.string(input, "groupID"),
                beforeGroupID: input["targetID"] as? String
            )
            try await save(draft, store: store)
        case "category-delete":
            let categoryID = try OracleJSON.string(input, "categoryID")
            let needs = await needsTransferValue { try await store.categoryNeedsTransfer(categoryID: categoryID, budgetID: budgetID) }
            _ = try await store.deleteCategoryAndRefresh(
                categoryID: categoryID,
                transferCategoryID: try payload()["transferId"] as? String,
                budgetID: budgetID, month: month
            )
            return needs
        case "group-delete":
            let groupID = try OracleJSON.string(input, "groupID")
            // BudgetCategoryDeletionWorkflow.prepareGroup asks about each of the group's categories in turn.
            let groups = try await store.budgetMonth(budgetID: budgetID, selectedMonth: month).month.categoryGroups
            let categoryIDs = groups.first { $0.id == groupID }?.categories.map(\.id) ?? []
            let needs = await needsTransferValue {
                for categoryID in categoryIDs where try await store.categoryNeedsTransfer(categoryID: categoryID, budgetID: budgetID) {
                    return true
                }
                return false
            }
            _ = try await store.deleteCategoryGroupAndRefresh(
                groupID: groupID,
                transferCategoryID: try payload()["transferId"] as? String,
                budgetID: budgetID, month: month
            )
            return needs
        default:
            throw OracleReplayError.malformedFixture("unknown case kind \(kind)")
        }
        return nil
    }

    private static func needsTransferValue(_ ask: () async throws -> Bool) async -> OracleValue {
        do {
            return .number(try await ask() ? 1 : 0)
        } catch {
            return .string("refused")
        }
    }

    private static func outlineDraft(store: LocalFirstActualStore) async throws -> BudgetCategoryOutlineDraft {
        let loaded = try await store.budgetMonth(budgetID: budgetID, selectedMonth: month)
        return BudgetCategoryOutlineDraft(groups: loaded.month.categoryGroups, isTrackingBudget: loaded.isTrackingBudget)
    }

    private static func save(_ draft: BudgetCategoryOutlineDraft, store: LocalFirstActualStore) async throws {
        guard let command = draft.command else { return }
        _ = try await store.applyCategoryOutlineAndRefresh(draft: command, budgetID: budgetID, month: month)
    }

    // MARK: Reads

    private static func read(
        kind: String,
        input: [String: Any],
        world: [String: Any],
        store: LocalFirstActualStore,
        database: BudgetDatabase
    ) async throws -> OracleValue {
        switch kind {
        case "read-must-transfer":
            let live = try OracleJSON.objects(world["categories"], "categories").filter { ($0["tombstone"] as? Int) == 0 }
            var result: [String: OracleValue] = [:]
            for row in live {
                let id = try OracleJSON.string(row, "id")
                result[id] = await needsTransferValue { try await store.categoryNeedsTransfer(categoryID: id, budgetID: budgetID) }
            }
            return .object(["mustTransfer": .object(result)])
        case "read-outline":
            return .object(["groups": await outline(store: store, order: false)])
        case "read-deleted-display":
            let accountID = try OracleJSON.string(input, "account")
            let loaded = try await store.loadedAccountTransactions(
                database: database, budgetID: budgetID, accountID: accountID, query: TransactionFeedQuery()
            )
            let rows = loaded.transactions.map { transaction -> OracleValue in
                .object([
                    "id": transaction.id.map(OracleValue.string) ?? .null,
                    "category": transaction.category.map(OracleValue.string) ?? .null,
                    "categoryName": transaction.category.flatMap { loaded.categoryNames[$0] }.map(OracleValue.string) ?? .null,
                ])
            }
            return .object(["transactions": .array(rows.sorted { ($0.rowID ?? "") < ($1.rowID ?? "") })])
        default:
            throw OracleReplayError.malformedFixture("unknown read \(kind)")
        }
    }

    /// The Budget screen's category groups (`budgetMonth(...).month.categoryGroups`), as the outline read
    /// (ids, names, hidden) or, with `order`, as group ids with their category ids.
    private static func outline(store: LocalFirstActualStore, order: Bool) async -> OracleValue {
        guard let groups = try? await store.budgetMonth(budgetID: budgetID, selectedMonth: month).month.categoryGroups else {
            return .string("unavailable")
        }
        return .array(groups.map { group in
            if order {
                return .object(["id": .string(group.id), "categories": .array(group.categories.map { .string($0.id) })])
            }
            return .object([
                "id": .string(group.id),
                "name": .string(group.name),
                "hidden": .number(group.hidden == true ? 1 : 0),
                "categories": .array(group.categories.map {
                    .object([
                        "id": .string($0.id),
                        "name": .string($0.name),
                        "hidden": .number($0.hidden == true ? 1 : 0),
                    ])
                }),
            ])
        })
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
                "category_groups": try table(
                    "SELECT id, name, is_income, hidden, sort_order, tombstone FROM category_groups ORDER BY id"
                ),
                "categories": try table(
                    "SELECT id, name, cat_group, is_income, hidden, sort_order, tombstone FROM categories ORDER BY id"
                ),
                "category_mapping": try table("SELECT id, transferId FROM category_mapping ORDER BY id"),
                "zero_budgets": try table(
                    "SELECT id, month, category, amount, carryover FROM zero_budgets WHERE month IN (202608, 202609) ORDER BY id"
                ),
            ])
        }
    }

    // MARK: Ordering and aliasing

    private static func seededIDs(_ world: [String: Any]) -> Set<String> {
        var ids: Set<String> = []
        for table in ["category_groups", "categories", "category_mapping"] {
            for row in (world[table] as? [[String: Any]]) ?? [] {
                if let id = row["id"] as? String { ids.insert(id) }
            }
        }
        return ids
    }

    /// Actual's minted ids are `uuid-N` by first appearance; the store mints UUIDs. Only category and group ids are minted.
    private static func newIDAliases(
        messages: [ActualSyncDecodedMessage],
        rows: OracleValue,
        seeded: Set<String>
    ) -> [String: String] {
        var ordered: [String] = []
        func note(_ id: String) {
            if !seeded.contains(id), !ordered.contains(id) { ordered.append(id) }
        }
        for message in messages where ["categories", "category_groups", "category_mapping"].contains(message.dataset) {
            note(message.row)
        }
        for table in ["category_groups", "categories", "category_mapping"] {
            if case .array(let items)? = rows.field(table) {
                for item in items {
                    if case .string(let id)? = item.field("id") { note(id) }
                }
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

    /// Seeds the world, then replaces whole tables with a case's `stateRows` (the state a case's own
    /// pre-read step left, such as another device's delete).
    private static func seed(_ database: BudgetDatabase, world: [String: Any], stateRows: [String: Any]) async throws {
        var rows: [SeedRow] = []
        for table in seedTables {
            for row in try OracleJSON.objects(world[table] ?? [], table) {
                rows.append(try insertion(table, row))
            }
        }
        var replacements: [(table: String, rows: [SeedRow])] = []
        for table in stateRows.keys.sorted() {
            replacements.append((table, try OracleJSON.objects(stateRows[table], table).map { try insertion(table, $0) }))
        }
        let insertions = rows
        let replaced = replacements
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
            for replacement in replaced {
                try db.execute(sql: "DELETE FROM \(replacement.table)")
                for row in replacement.rows {
                    try db.execute(sql: row.sql, arguments: StatementArguments(row.values as [any DatabaseValueConvertible]))
                }
            }
        }
    }
}
