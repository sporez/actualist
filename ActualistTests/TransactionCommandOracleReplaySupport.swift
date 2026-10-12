import Foundation
import GRDB
@testable import Actualist

/// Replays the Transaction Command oracle (duplicate D1/D2 and merge M1-M4) through the production
/// `BudgetDatabase` review, commit and ActionLog undo paths on a starter-schema budget seeded from the
/// fixture rows. No case needs the pure planners: every input is expressible as stored rows.
///
/// Compared per case: allowed versus refused; for a merge the kept row; every comparable column of
/// every row after the command; and, when allowed, the rows after undo. Not compared: `sort_order`
/// (Actual's is the frozen clock 123456789; Actualist allocates a fresh order by contract), the refusal
/// text (typed reasons versus strings), and the CRDT message lists (Actual repeats cells; Actualist
/// writes only changed cells). Minted ids are compared by structure: a new row is named by its own
/// content, and its parent or transfer link by the linked row's content.
@MainActor
enum TransactionCommandOracleReplay {
    static let now = Date(timeIntervalSince1970: 1_789_344_000)

    /// Fixture key -> physical `transactions` column.
    private static let transactionColumns: [(key: String, column: String)] = [
        ("id", "id"), ("is_parent", "isParent"), ("is_child", "isChild"), ("account", "acct"),
        ("category_mapping_id", "category"), ("amount", "amount"), ("payee_mapping_id", "description"),
        ("notes", "notes"), ("date", "date"), ("imported_id", "financial_id"), ("type", "type"),
        ("location", "location"), ("error", "error"), ("imported_payee", "imported_description"),
        ("starting_balance_flag", "starting_balance_flag"), ("transfer_id", "transferred_id"),
        ("sort_order", "sort_order"), ("tombstone", "tombstone"), ("cleared", "cleared"),
        ("pending", "pending"), ("parent_id", "parent_id"), ("schedule", "schedule"),
        ("reconciled", "reconciled"), ("raw_synced_data", "raw_synced_data"),
    ]

    private static let uncomparableKeys: Set<String> = ["sort_order"]

    private struct Session {
        let database: BudgetDatabase
        let queue: DatabaseQueue
    }

    private enum Applied {
        case refused
        case committed(actionID: String, kept: String?)
    }

    // MARK: - Expected

    static func expected(_ entry: [String: Any]) throws -> OracleValue {
        let input = try OracleJSON.objects(OracleJSON.object(entry["input"], "input")["transactions"], "transactions")
        let seeded = Set(input.compactMap { $0["id"] as? String })
        let handler = try OracleJSON.object(entry["handler"], "handler")
        let afterHandler = try OracleJSON.object(entry["afterHandler"], "afterHandler")
        var fields: [String: OracleValue] = [:]
        if try OracleJSON.string(handler, "outcome") != "ok" {
            fields["outcome"] = .string("refused")
            fields["rows"] = try canonical(fixtureRows(afterHandler["transactions"]), seeded: seeded)
            return .object(fields)
        }
        fields["outcome"] = .string("ok")
        if let kept = handler["result"] as? String {
            fields["kept"] = .string(kept)
        }
        fields["rows"] = try canonical(fixtureRows(afterHandler["transactions"]), seeded: seeded)
        let undo = try OracleJSON.object(entry["undo"], "undo")
        fields["undo"] = .object([
            "outcome": .string(try OracleJSON.string(undo, "outcome")),
            "rows": try canonical(fixtureRows(undo["transactions"]), seeded: seeded),
        ])
        if let rules = entry["rules"] as? [String: Any] {
            fields["rules"] = .object([
                "afterHandler": .number(Double((rules["afterHandler"] as? [Any])?.count ?? -1)),
                "afterUndo": .number(Double((rules["afterUndo"] as? [Any])?.count ?? -1)),
            ])
        }
        return .object(fields)
    }

    /// The fixture's seeded rows in comparison form: what an untouched database holds.
    static func seededRows(_ entry: [String: Any]) throws -> OracleValue {
        let input = try OracleJSON.object(entry["input"], "input")
        let rows = try OracleJSON.objects(input["transactions"], "transactions")
        return try canonical(fixtureRows(rows), seeded: Set(rows.compactMap { $0["id"] as? String }))
    }

    private static func fixtureRows(_ value: Any?) throws -> [[String: OracleValue]] {
        try OracleJSON.objects(value, "transactions").map { row in
            var fields: [String: OracleValue] = [:]
            for (key, _) in transactionColumns where !uncomparableKeys.contains(key) {
                fields[key] = try OracleValue(json: row[key] ?? NSNull())
            }
            return fields
        }
    }

    // MARK: - Replay

    static func replay(
        entry: [String: Any],
        referenceData: [String: Any],
        makeDirectory: () throws -> URL
    ) async throws -> OracleValue {
        let permit = await OracleReplayGate.shared.acquire()
        defer { permit.release() }
        let caseID = try OracleJSON.string(entry, "id")
        let input = try OracleJSON.objects(OracleJSON.object(entry["input"], "input")["transactions"], "transactions")
        let seeded = Set(input.compactMap { $0["id"] as? String })
        let url = try makeDirectory().appending(path: "db.sqlite")
        let database = try await OracleReplayDatabase.starter(at: url, localNodeID: "node1")
        let session = try open(rows: input, referenceData: referenceData, database: database, url: url)
        let selected = (entry["selected"] as? [String]) ?? []

        let applied: Applied
        if caseID.hasPrefix("D") {
            applied = try await duplicate(session, selected: selected, input: input)
        } else {
            applied = try await merge(session, selected: selected)
        }

        var fields: [String: OracleValue] = [:]
        let rowsAfter = try canonical(readRows(session), seeded: seeded)
        guard case .committed(let actionID, let kept) = applied else {
            fields["outcome"] = .string("refused")
            fields["rows"] = rowsAfter
            return .object(fields)
        }
        fields["outcome"] = .string("ok")
        if let kept {
            fields["kept"] = .string(kept)
        }
        fields["rows"] = rowsAfter
        let rulesAfterHandler = try ruleCount(session)

        if let conflict = entry["conflict"] as? [String: Any] {
            try await applyConflict(session, conflict)
        }
        let undoOutcome = try await undo(session, actionID: actionID)
        fields["undo"] = .object([
            "outcome": .string(undoOutcome),
            "rows": try canonical(readRows(session), seeded: seeded),
        ])
        if entry["rules"] != nil {
            fields["rules"] = .object([
                "afterHandler": .number(Double(rulesAfterHandler)),
                "afterUndo": .number(Double(try ruleCount(session))),
            ])
        }
        return .object(fields)
    }

    private static func duplicate(
        _ session: Session,
        selected: [String],
        input: [[String: Any]]
    ) async throws -> Applied {
        let byID = Dictionary(uniqueKeysWithValues: input.compactMap { row in
            (row["id"] as? String).map { ($0, row) }
        })
        let selections = try selected.map { id -> TransactionSelectionIdentity in
            let row = try OracleJSON.object(byID[id], "selected row \(id)")
            let isChild = OracleJSON.int(row["is_child"]) == 1
            guard let identity = TransactionSelectionIdentity(
                transactionID: id,
                familyRootID: isChild ? (row["parent_id"] as? String ?? id) : id,
                role: isChild ? .child : .root
            ) else {
                throw OracleReplayError.malformedFixture("selected row \(id) has no selection identity")
            }
            return identity
        }
        do {
            let review = try await session.database.reviewTransactionDuplicate(
                context: makeCommandContext(),
                selections: selections,
                cloneIDAtIndex: { "clone-\($0)" },
                now: now
            )
            guard review.canSubmit else {
                return .refused
            }
            _ = try await session.database.commitTransactionDuplicate(review: review, now: now)
            return .committed(actionID: review.id, kept: nil)
        } catch is LocalFirstError {
            return .refused
        }
    }

    private static func merge(_ session: Session, selected: [String]) async throws -> Applied {
        do {
            let review = try await session.database.reviewTransactionMerge(
                context: makeCommandContext(),
                orderedTransactionIDs: selected
            )
            guard review.canSubmit, review.blockedReason == nil else {
                return .refused
            }
            // Actual merges reconciled rows without asking; Actualist asks first, so the replay
            // answers the confirmation. That is a UI step, not a refusal.
            let authorization = review.reconciledTransactionIDs.isEmpty ? nil : TransactionMergeAuthorization(
                reviewID: review.id,
                reviewFingerprint: review.reviewFingerprint,
                reconciledTransactionIDs: review.reconciledTransactionIDs
            )
            _ = try await session.database.commitTransactionMerge(
                review: review,
                authorization: authorization,
                now: now
            )
            return .committed(actionID: review.id, kept: review.keptRow?.transactionID)
        } catch is LocalFirstError {
            return .refused
        }
    }

    /// `ok` when the undo applied, `blocked` when the conflict check refused it, `missing` without an
    /// ActionLog record.
    private static func undo(_ session: Session, actionID: String) async throws -> String {
        guard let record = try await session.database.actionLogRecord(id: actionID) else {
            return "missing"
        }
        let preview = try await session.database.actionUndoPreview(record: record)
        guard preview.block == nil else {
            return "blocked"
        }
        do {
            _ = try await session.database.commitActionUndo(record: record, now: now)
            return "ok"
        } catch LocalFirstError.actionUndoBlocked(_) {
            return "blocked"
        }
    }

    /// The fixture's post-merge edit, written through the same local-write path a later user edit takes.
    private static func applyConflict(_ session: Session, _ conflict: [String: Any]) async throws {
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try OracleJSON.objects(conflict["messages"], "conflict.messages").map { message in
            let value: LocalFirstSyncValue
            switch message["value"] {
            case let text as String:
                value = .string(text)
            case let number as NSNumber:
                value = .int(number.int64Value)
            default:
                value = .null
            }
            return try builder.makeMessage(
                dataset: try OracleJSON.string(message, "dataset"),
                row: try OracleJSON.string(message, "row"),
                column: try OracleJSON.string(message, "column"),
                value: value
            )
        }
        try await session.database.commitLocalSyncMessagesAndEnqueue(messages)
    }

    // MARK: - Projection

    private static func readRows(_ session: Session) throws -> [[String: OracleValue]] {
        let select = transactionColumns
            .filter { !uncomparableKeys.contains($0.key) }
            .map { "\($0.column) AS \($0.key)" }
            .joined(separator: ", ")
        return try session.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT \(select) FROM transactions").map { row in
                var fields: [String: OracleValue] = [:]
                for (key, _) in transactionColumns where !uncomparableKeys.contains(key) {
                    fields[key] = OracleValue.databaseValue(row[key])
                }
                return fields
            }
        }
    }

    private static func ruleCount(_ session: Session) throws -> Int {
        try session.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rules WHERE COALESCE(tombstone, 0) = 0") ?? 0
        }
    }

    /// Rows sorted by content with new ids and their links replaced by the content they point at.
    private static func canonical(_ rows: [[String: OracleValue]], seeded: Set<String>) -> OracleValue {
        let byID = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, [String: OracleValue])? in
            guard case .string(let id)? = row["id"] else {
                return nil
            }
            return (id, row)
        })
        func signature(_ row: [String: OracleValue]) -> String {
            OracleValue.object(row.filter { !["id", "parent_id", "transfer_id"].contains($0.key) }).canonical
        }
        func isNew(_ value: OracleValue?) -> [String: OracleValue]? {
            guard case .string(let id)? = value, !seeded.contains(id) else {
                return nil
            }
            return byID[id]
        }
        func link(_ value: OracleValue?) -> OracleValue {
            if let target = isNew(value) {
                return .string("new[\(signature(target))]")
            }
            return value ?? .null
        }
        let named = rows.map { row -> OracleValue in
            var fields = row
            fields["id"] = isNew(row["id"]).map { .string("new[\(signature($0))]") } ?? row["id"] ?? .null
            // A tombstoned row's links are not compared: they are unobservable, and Actual clears or
            // keeps them on dead rows depending on the handler and on undo.
            let isDead = row["tombstone"] == .number(1)
            fields["parent_id"] = isDead ? .null : link(row["parent_id"])
            fields["transfer_id"] = isDead ? .null : link(row["transfer_id"])
            return .object(fields)
        }
        return .array(named.sorted { $0.canonical < $1.canonical })
    }

    // MARK: - Seeding

    private static let referenceTables: [(key: String, table: String, rename: [String: String])] = [
        ("accounts", "accounts", [:]),
        ("categoryGroups", "category_groups", [:]),
        ("categories", "categories", [:]),
        ("categoryMappings", "category_mapping", ["category_id": "transferId"]),
        ("payees", "payees", [:]),
        ("payeeMappings", "payee_mapping", ["payee_id": "targetId"]),
        ("schedules", "schedules", [:]),
    ]

    private static func open(
        rows: [[String: Any]],
        referenceData: [String: Any],
        database: BudgetDatabase,
        url: URL
    ) throws -> Session {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            for table in ["transactions", "rules", "schedules", "payee_mapping", "payees",
                          "category_mapping", "categories", "category_groups", "accounts"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            for reference in referenceTables {
                for row in try OracleJSON.objects(referenceData[reference.key] ?? [], reference.key) {
                    try insert(row, into: reference.table, rename: reference.rename, db: db)
                }
            }
            let physical = Dictionary(uniqueKeysWithValues: transactionColumns.map { ($0.key, $0.column) })
            for row in rows {
                try insert(row, into: "transactions", rename: physical, db: db)
            }
        }
        return Session(database: database, queue: queue)
    }

    private static func insert(
        _ row: [String: Any],
        into table: String,
        rename: [String: String],
        db: Database
    ) throws {
        let keys = row.keys.sorted()
        let columns = keys.map { rename[$0] ?? $0 }
        let marks = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        try db.execute(
            sql: "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(marks))",
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
