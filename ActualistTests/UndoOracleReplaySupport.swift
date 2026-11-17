import Foundation
import GRDB
@testable import Actualist

/// Replays the Undo oracle contract. Each case seeds the fixture's `world` into a starter-schema
/// budget, performs the action through the production store write the UI uses, undoes the newest
/// History record with `undoBudgetActionAndRefresh`, and compares the rows before, after the action
/// and after the undo, the net writes of the undo, and whether the undo was offered and applied.
/// `replayPayeeUndo` does the same for the Payees fixture's recorded `undo` through the store's
/// one-step payee undo. The compared and excluded parts are in `scripts/undo-parity/README.md`.
@MainActor
enum UndoOracleReplay {
    private static let budgetID = "budget"
    private static let month = "2026-09"

    /// Tables the world seeds, parents before children.
    private static let seedTables = [
        "accounts", "category_groups", "categories", "category_mapping", "payees", "payee_mapping",
        "zero_budgets", "zero_budget_months", "transactions",
    ]
    /// Cleared before seeding, children before parents; `preferences` returns the budget to its envelope default.
    private static let clearedTables = [
        "transactions", "schedules_next_date", "schedules", "rules", "payee_mapping", "payees",
        "zero_budgets", "reflect_budgets", "zero_budget_months", "reflect_budget_months",
        "category_mapping", "categories", "category_groups", "accounts", "preferences",
    ]
    private static let aliasedDatasets: Set<String> = ["transactions", "payees", "payee_mapping"]

    // MARK: Expected

    /// What Actual recorded for the case, in comparison form. The undo outcome is derived from what
    /// `undo()` did: it wrote messages, wrote none, or threw.
    static func expected(_ entry: [String: Any]) throws -> OracleValue {
        let undoErrors = entry["undoErrors"] as? [Any] ?? []
        let undoMessages = try OracleJSON.objects(entry["undoMessages"], "undoMessages")
        let outcome = !undoErrors.isEmpty ? "error" : undoMessages.isEmpty ? "nothing" : "applied"
        return .object([
            "outcome": .string(outcome),
            "rowsBefore": try comparableRows(OracleValue(json: entry["rowsBefore"] ?? NSNull())),
            "rowsAfterAction": try comparableRows(OracleValue(json: entry["rowsAfterAction"] ?? NSNull())),
            "undoWrites": OracleWriteReplay.sortedWrites(try OracleValue(json: entry["undoWrites"] ?? NSNull())),
            "rowsAfterUndo": try comparableRows(OracleValue(json: entry["rowsAfterUndo"] ?? NSNull())),
        ])
    }

    /// Rows ordered by id, without `sort_order`: Actual's is the frozen clock (123456789 for a row
    /// that has none, the frozen day in ms for a new one); Actualist allocates a fresh order.
    private static func comparableRows(_ rows: OracleValue) -> OracleValue {
        guard case .object(var tables) = OracleWriteReplay.sortedRows(rows),
              case .array(let transactions)? = tables["transactions"] else {
            return rows
        }
        tables["transactions"] = .array(transactions.map { row in
            guard case .object(var fields) = row else { return row }
            for key in TransactionCommandOracleReplay.uncomparableKeys { fields[key] = nil }
            return .object(fields)
        })
        return .object(tables)
    }

    // MARK: Replay

    static func replay(entry: [String: Any], world: [String: Any]) async throws -> OracleValue {
        let permit = await OracleReplayGate.shared.acquire()
        defer { permit.release() }
        let kind = try OracleJSON.string(entry, "kind")
        let input = try OracleJSON.object(entry["input"], "input")

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "UndoOracleReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
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

        let rowsBefore = try await readRows(database)
        var outcome: String
        do {
            try await perform(kind: kind, input: input, store: store)
            outcome = "not-offered"
        } catch {
            outcome = "action-refused"
        }
        let forward = try await database.pendingLocalSyncMessages(limit: 100_000).map(\.message)
        let rowsAfterAction = try await readRows(database)

        if outcome == "not-offered", let record = try await ActionLogStorageSQL.recentBudgetActions(in: database).first {
            outcome = await undoOutcome(actionID: record.id, store: store)
        }
        let undone = try await database.pendingLocalSyncMessages(limit: 100_000).map(\.message).dropFirst(forward.count)
        let rowsAfterUndo = try await readRows(database)

        let aliases = newIDAliases(
            messages: forward + undone,
            rows: [rowsBefore, rowsAfterAction, rowsAfterUndo],
            seeded: seededIDs(world)
        )
        func rows(_ value: OracleValue) -> OracleValue {
            comparableRows(OracleWriteReplay.aliased(value, aliases))
        }
        return .object([
            "outcome": .string(outcome),
            "rowsBefore": rows(rowsBefore),
            "rowsAfterAction": rows(rowsAfterAction),
            "undoWrites": OracleWriteReplay.sortedWrites(
                OracleWriteReplay.aliased(OracleWriteReplay.netWrites(Array(undone)), aliases)
            ),
            "rowsAfterUndo": rows(rowsAfterUndo),
        ])
    }

    /// `applied` when History offers the undo and it commits; `blocked` when the preview or the commit
    /// refuses it; `not-offered` when there is no preview to show.
    private static func undoOutcome(actionID: String, store: LocalFirstActualStore) async -> String {
        do {
            let preview = try await store.history.budgetActionUndoPreview(actionID: actionID, budgetID: budgetID)
            if preview.block != nil { return "blocked" }
        } catch {
            return "not-offered"
        }
        do {
            try await store.history.undoBudgetActionAndRefresh(actionID: actionID, budgetID: budgetID)
            return "applied"
        } catch {
            return "blocked"
        }
    }

    // MARK: Actions

    /// The production write for the case: the store method the mobile editor, the budget cell, the move
    /// sheet and the selection toolbar call.
    private static func perform(kind: String, input: [String: Any], store: LocalFirstActualStore) async throws {
        switch kind {
        case "assign":
            _ = try await store.budget.assignCategoryBudgetAndRefresh(
                categoryID: try OracleJSON.string(input, "categoryID"),
                budgeted: OracleJSON.int(input["amount"]) ?? 0,
                budgetID: budgetID,
                month: try OracleJSON.string(input, "month"),
                didAssign: {}
            )
        case "move":
            _ = try await store.budget.moveMoneyAndRefresh(
                commands: [BudgetMoveMoneyCommand.move(
                    fromCategoryID: try OracleJSON.string(input, "fromID"),
                    toCategoryID: try OracleJSON.string(input, "toID"),
                    amount: OracleJSON.int(input["amount"]) ?? 0
                )],
                budgetID: budgetID,
                month: try OracleJSON.string(input, "month"),
                didMove: {}
            )
        case "create":
            let amount = OracleJSON.int(input["amount"]) ?? 0
            let draft = try submissionDraft(
                accountID: try OracleJSON.string(input, "accountID"),
                amount: amount,
                payeeName: "",
                notes: "",
                cleared: false,
                categoryID: input["categoryID"] as? String,
                date: try date(try OracleJSON.string(input, "date"))
            )
            _ = try await store.createTransactionAndRefresh(draft, budgetID: budgetID, didCreate: {})
        case "edit":
            let existing = try await existingTransaction(store, input)
            let draft = try submissionDraft(
                accountID: existing.account,
                amount: OracleJSON.int(input["amount"]) ?? 0,
                payeeName: try OracleJSON.string(input, "newPayeeName"),
                notes: existing.notes ?? "",
                cleared: existing.cleared?.boolValue ?? false,
                categoryID: existing.category,
                date: try date(existing.date),
                realImportedPayee: existing.importedPayee,
                reconciled: existing.reconciled,
                originalIsParent: existing.isParent
            )
            _ = try await store.updateTransactionAndRefresh(
                try OracleJSON.string(input, "transactionID"),
                with: draft,
                budgetID: budgetID,
                originalAccountID: existing.account,
                originalMonth: String(existing.date.prefix(7)),
                baseline: existing,
                didUpdate: {}
            )
        case "delete":
            _ = try await store.deleteTransactionAndRefresh(
                try await existingTransaction(store, input), budgetID: budgetID, didDelete: {}
            )
        case "categorize":
            _ = try await store.categorizeTransactionAndRefresh(
                try await existingTransaction(store, input),
                categoryID: try OracleJSON.string(input, "categoryID"),
                budgetID: budgetID,
                didUpdate: {}
            )
        case "batch-delete":
            try await commitBatch(store, ids: input["ids"] as? [String] ?? [], intent: .delete)
        case "batch-categorize":
            try await commitBatch(
                store,
                ids: input["ids"] as? [String] ?? [],
                intent: .categorize(categoryID: try OracleJSON.string(input, "categoryID"))
            )
        default:
            throw OracleReplayError.malformedFixture("unknown case kind \(kind)")
        }
    }

    private static func existingTransaction(
        _ store: LocalFirstActualStore,
        _ input: [String: Any]
    ) async throws -> ActualTransaction {
        let id = try OracleJSON.string(input, "transactionID")
        guard let transaction = try await store.fetchTransaction(budgetID: budgetID, id: id) else {
            throw OracleReplayError.malformedFixture("transaction \(id) is not seeded")
        }
        return transaction
    }

    /// The draft the transaction editor submits, through its own builder.
    private static func submissionDraft(
        accountID: String,
        amount: Int,
        payeeName: String,
        notes: String,
        cleared: Bool,
        categoryID: String?,
        date: Date,
        realImportedPayee: String? = nil,
        reconciled: Bool = false,
        originalIsParent: Bool = false
    ) throws -> TransactionDraft {
        let input = TransactionDraftBuilder.SubmissionInput(
            accountID: accountID,
            amountCents: abs(amount),
            kind: amount < 0 ? .spend : .inflow,
            payeeID: nil,
            payeeName: payeeName,
            notes: notes,
            cleared: cleared,
            categoryID: categoryID,
            isCategoryReadOnly: false,
            isSplit: false,
            isTransfer: false,
            realImportedPayee: realImportedPayee,
            reconciled: reconciled,
            originalIsParent: originalIsParent,
            date: date,
            splitDrafts: []
        )
        guard let draft = TransactionDraftBuilder.makeSubmissionDraft(from: input) else {
            throw OracleReplayError.malformedFixture("the editor builds no draft for this input")
        }
        return draft
    }

    /// The selection toolbar's review, then the review sheet's confirmation.
    private static func commitBatch(
        _ store: LocalFirstActualStore,
        ids: [String],
        intent: TransactionBatchIntent
    ) async throws {
        var selections: [TransactionSelectionIdentity] = []
        for id in ids {
            guard let transaction = try await store.fetchTransaction(budgetID: budgetID, id: id),
                  let selection = TransactionSelectionIdentity(transaction: transaction) else {
                throw OracleReplayError.malformedFixture("transaction \(id) has no selection identity")
            }
            selections.append(selection)
        }
        let review = try await store.transactionCommands.reviewTransactionBatch(
            context: TransactionSelectionContext(
                budgetID: budgetID,
                sessionGeneration: store.budgetSessionGeneration,
                scope: .spending,
                querySignature: TransactionFeedQuery().signature
            ),
            intent: intent,
            selections: selections
        )
        guard review.canSubmit else {
            throw LocalFirstError.refusedChange("The review cannot be submitted.")
        }
        _ = try await store.transactionCommands.commitTransactionBatch(review: review, authorization: review.authorization)
    }

    private static func date(_ dayID: String) throws -> Date {
        guard let date = ActualDateOnly.date(from: dayID, timeZone: .autoupdatingCurrent) else {
            throw OracleReplayError.malformedFixture("bad date \(dayID)")
        }
        return date
    }

    // MARK: Payee undo

    /// What Actual recorded for a Payees case's `undo()`, in comparison form: its net writes, the rows
    /// afterwards, and that it applied.
    static func expectedPayeeUndo(_ entry: [String: Any]) throws -> OracleValue {
        let undo = try OracleJSON.object(entry["undo"], "undo")
        let messages = try OracleJSON.objects(undo["messages"], "undo.messages")
        var last: [String: [String: Any]] = [:]
        for message in messages {
            let key = ["dataset", "row", "column"].map { (message[$0] as? String) ?? "" }.joined(separator: "\u{0}")
            last[key] = message
        }
        return .object([
            "outcome": .string(undo["error"] is NSNull ? "applied" : "error"),
            "writes": OracleWriteReplay.sortedWrites(.array(try last.values.map { try OracleValue(json: $0) })),
            "rows": OracleWriteReplay.sortedRows(try OracleValue(json: undo["rows"] ?? NSNull())),
        ])
    }

    /// Performs the Payees case through the store's payee command (the Payees suite's own seeding and
    /// command), then calls the store's one-step payee undo and reads only what the undo appended.
    static func replayPayeeUndo(entry: [String: Any], world: [String: Any]) async throws -> OracleValue {
        let permit = await OracleReplayGate.shared.acquire()
        defer { permit.release() }
        let kind = try OracleJSON.string(entry, "kind")
        let input = try OracleJSON.object(entry["input"], "input")

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "UndoOracleReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "db.sqlite")
        let database = try await OracleReplayDatabase.starter(at: url, localNodeID: "node1")
        let preferences = try OracleJSON.objects(entry["preferencesSeed"] ?? [], "preferencesSeed")
        try await PayeeOracleReplay.seed(database, world: world, preferences: preferences)

        let store = LocalFirstActualStore(
            keychain: KeychainStore(service: UUID().uuidString, account: "token", backend: FakeKeychainBackend())
        )
        store.openedBudgetID = budgetID
        store.database = database
        try await PayeeOracleReplay.perform(kind: kind, input: input, call: entry["handlerCall"], store: store)

        let forward = try await database.pendingLocalSyncMessages(limit: 100_000).map(\.message)
        let includePreferences = kind == "global-learning"
        let rowsAfterAction = try await PayeeOracleReplay.readRows(database, includePreferences: includePreferences)
        var outcome = "applied"
        do {
            try await store.payees.undoLastPayeeMutationAndRefresh(budgetID: budgetID)
        } catch {
            outcome = "refused"
        }
        let undone = try await database.pendingLocalSyncMessages(limit: 100_000).map(\.message).dropFirst(forward.count)
        let rowsAfterUndo = try await PayeeOracleReplay.readRows(database, includePreferences: includePreferences)

        let aliases = PayeeOracleReplay.newIDAliases(
            messages: forward + undone,
            rows: rowsAfterAction,
            seeded: PayeeOracleReplay.seededIDs(world)
        )
        return .object([
            "outcome": .string(outcome),
            "writes": OracleWriteReplay.sortedWrites(
                OracleWriteReplay.aliased(OracleWriteReplay.netWrites(Array(undone)), aliases)
            ),
            "rows": OracleWriteReplay.sortedRows(OracleWriteReplay.aliased(rowsAfterUndo, aliases)),
        ])
    }

    // MARK: Rows

    /// The same four tables Actual's runner records, with `transactions` under the transaction-command
    /// harness's column names.
    private static func readRows(_ database: BudgetDatabase) async throws -> OracleValue {
        let select = TransactionCommandOracleReplay.transactionColumns
            .map { "\($0.column) AS \($0.key)" }
            .joined(separator: ", ")
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
                "transactions": try table("SELECT \(select) FROM transactions ORDER BY id"),
                "zero_budgets": try table(
                    "SELECT id, month, category, amount, carryover FROM zero_budgets WHERE month = 202609 ORDER BY id"
                ),
                "payees": try table(
                    "SELECT id, name, transfer_acct, favorite, learn_categories, tombstone FROM payees ORDER BY id"
                ),
                "payee_mapping": try table("SELECT id, targetId FROM payee_mapping ORDER BY id"),
            ])
        }
    }

    // MARK: Aliasing

    /// Ids the world seeds; an id outside it is one the action minted.
    private static func seededIDs(_ world: [String: Any]) -> Set<String> {
        var ids: Set<String> = []
        for table in ["transactions", "payees", "payee_mapping"] {
            for row in (world[table] as? [[String: Any]]) ?? [] {
                if let id = row["id"] as? String { ids.insert(id) }
            }
        }
        return ids
    }

    /// Actual's minted ids are `uuid-N` by first appearance; the store mints UUIDs. Only transaction and
    /// payee ids are minted.
    private static func newIDAliases(
        messages: [ActualSyncDecodedMessage],
        rows: [OracleValue],
        seeded: Set<String>
    ) -> [String: String] {
        var ordered: [String] = []
        func note(_ id: String) {
            if !seeded.contains(id), !ordered.contains(id) { ordered.append(id) }
        }
        for message in messages where aliasedDatasets.contains(message.dataset) {
            note(message.row)
        }
        for snapshot in rows {
            for table in ["transactions", "payees"] {
                if case .array(let items)? = snapshot.field(table) {
                    for item in items {
                        if case .string(let id)? = item.field("id") { note(id) }
                    }
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

    private static func seed(_ database: BudgetDatabase, world: [String: Any]) async throws {
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
