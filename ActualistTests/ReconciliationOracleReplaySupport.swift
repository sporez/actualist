import Foundation
import GRDB
@testable import Actualist

/// Replays Reconciliation oracle cases through the production `BudgetDatabase` writes on a seeded
/// SQLite budget, then projects each outcome into the oracle's JSON shape.
@MainActor
enum ReconciliationOracleReplay {
    static let accountID = "checking"
    static let now = Date(timeIntervalSince1970: 1_789_344_000)

    /// Transaction columns and the rules table the reconciliation writes read. The base fixture
    /// already provides accounts, the `checking` account, and an uncleared `txn` row.
    private static let schemaSQL = """
        ALTER TABLE accounts ADD COLUMN last_reconciled TEXT;
        ALTER TABLE transactions ADD COLUMN description TEXT;
        ALTER TABLE transactions ADD COLUMN notes TEXT;
        ALTER TABLE transactions ADD COLUMN cleared INTEGER DEFAULT 0;
        ALTER TABLE transactions ADD COLUMN isChild INTEGER DEFAULT 0;
        ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
        CREATE TABLE rules (id TEXT PRIMARY KEY, conditions TEXT, actions TEXT, tombstone INTEGER);
        """

    /// The adjustment-rule-delete fixture's rule: delete the reconciliation adjustment itself.
    private static let deleteRuleConditions =
        #"[{"field":"notes","op":"is","value":"Reconciliation balance adjustment"}]"#
    private static let deleteRuleActions = #"[{"op":"delete-transaction","value":""}]"#

    private struct Session {
        let database: BudgetDatabase
        let queue: DatabaseQueue
    }

    static func replay(
        caseID: String,
        input: [String: Any],
        readback: [String: Any]?,
        makeFixture: (String) throws -> URL
    ) async throws -> OracleValue {
        let permit = await OracleReplayGate.shared.acquire()
        defer { permit.release() }
        switch caseID {
        case "cleared-balance":
            let account = try OracleJSON.string(input, "accountRef")
            let session = try open(
                rows: try OracleJSON.objects(input["scriptedRows"], "scriptedRows"),
                makeFixture: makeFixture
            )
            let snapshot = try await session.database.accountReconciliationSnapshot(accountID: account)
            return .object(["balance": .number(Double(snapshot.clearedBalance))])

        case "finish":
            let zero = try await finish(
                try OracleJSON.object(input["zeroDifference"], "zeroDifference"),
                makeFixture: makeFixture
            )
            let nonzero = try await finish(
                try OracleJSON.object(input["nonzeroDifference"], "nonzeroDifference"),
                makeFixture: makeFixture
            )
            var fields: [String: OracleValue] = [
                "zeroDifferenceLocks": .number(Double(zero.locks)),
                "nonzeroDifferenceLocks": .number(Double(nonzero.locks)),
            ]
            if zero.threw {
                fields["zeroDifferenceError"] = .string("thrown")
            }
            if nonzero.threw {
                fields["nonzeroDifferenceError"] = .string("thrown")
            }
            return .object(fields)

        case "lock":
            let session = try open(
                rows: try OracleJSON.objects(input["rows"], "rows"),
                makeFixture: makeFixture
            )
            let snapshot = try await session.database.accountReconciliationSnapshot(accountID: accountID)
            _ = try await session.database.finishReconciliation(
                accountID: accountID,
                targetBalance: snapshot.clearedBalance,
                now: now
            )
            return try await rowCells(session)

        case "unlock", "unlock-split-member", "unlock-split-parent",
            "unlock-split-member-unreconciled-parent", "unlock-simple-row":
            let transactionID = try OracleJSON.string(input, "transactionId")
            let session = try open(
                rows: try OracleJSON.objects(input["rows"], "rows"),
                makeFixture: makeFixture
            )
            _ = try await session.database.unlockReconciledTransaction(
                accountID: accountID,
                transactionID: transactionID,
                now: now
            )
            var fields: [String: OracleValue] = ["messages": try await rowCells(session)]
            if readback != nil {
                fields["after"] = try reconciledFlags(session, ids: seededIDs(input["rows"] as? [[String: Any]] ?? []))
            }
            return .object(fields)

        case "adjustment-rule-delete":
            let session = try open(
                rules: [(deleteRuleConditions, deleteRuleActions)],
                makeFixture: makeFixture
            )
            let write = try await adjust(session, diff: OracleJSON.int(input["diff"]) ?? 0)
            let rows = try adjustmentRows(session, write)
            return .object([
                "addedCount": .number(Double(rows.added.count)),
                "deletedCount": .number(Double(rows.deleted.count)),
                "deleted": .array(rows.deleted),
            ])

        case "adjustment-rule-clears-notes":
            let rule = try OracleJSON.object(input["rule"], "rule")
            let session = try open(
                rules: [(try jsonText(rule["conditions"]), try jsonText(rule["actions"]))],
                makeFixture: makeFixture
            )
            let write = try await adjust(session, diff: OracleJSON.int(input["diff"]) ?? 0)
            let rows = try adjustmentRows(session, write)
            return .object([
                "added": .array(rows.added),
                "deleted": .array(rows.deleted),
            ])

        default:
            throw OracleReplayError.unknownCase(caseID)
        }
    }

    /// Drops the fixture keys this replay does not produce: the `query` the balance read was built
    /// from, and the `realized` row the oracle's rule stage recorded before the adjustment write.
    static func expectedValue(
        _ caseID: String,
        input: [String: Any],
        readback: [String: Any]?,
        _ value: OracleValue
    ) throws -> OracleValue {
        switch caseID {
        case "lock":
            return expectedRowCells(input, value)
        case _ where caseID.hasPrefix("unlock"):
            var fields: [String: OracleValue] = ["messages": expectedRowCells(input, value)]
            if let readback {
                fields["after"] = try OracleValue(json: OracleJSON.object(readback["after"], "readback.after"))
            }
            return .object(fields)
        default:
            break
        }
        guard case .object(var fields) = value else {
            return value
        }
        switch caseID {
        case "cleared-balance":
            fields["query"] = nil
        case "adjustment-rule-clears-notes":
            fields["realized"] = nil
        default:
            break
        }
        return .object(fields)
    }

    /// Expected cells are sorted by id, as `rowCells` sorts them. An expected null is dropped only
    /// when the seeded row already holds null or no value for that column: that write changes
    /// nothing, so no outbox message records it. A null over a non-null seeded value stays required.
    private static func expectedRowCells(_ input: [String: Any], _ value: OracleValue) -> OracleValue {
        guard case .array(let rows) = value else {
            return value
        }
        let seeded = nonNullKeys(input["rows"] as? [[String: Any]] ?? [])
        return OracleValue.array(rows.map { row in
            guard case .object(let fields) = row, case .string(let id)? = fields["id"] else {
                return row
            }
            return .object(fields.filter { key, cell in
                cell != .null || key == "id" || seeded[id]?.contains(key) == true
            })
        }).sortedByID
    }

    /// Keys whose seeded value is non-null, by row id, including embedded subtransactions.
    private static func nonNullKeys(_ rows: [[String: Any]]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for row in rows {
            guard let id = row["id"] as? String else {
                continue
            }
            result[id] = Set(row.compactMap { key, cell in cell is NSNull ? nil : key })
            result.merge(nonNullKeys(row["subtransactions"] as? [[String: Any]] ?? [])) { _, child in child }
        }
        return result
    }

    // MARK: - Writes

    private static func adjust(_ session: Session, diff: Int) async throws -> AccountReconciliationDatabaseWrite {
        let snapshot = try await session.database.accountReconciliationSnapshot(accountID: accountID)
        return try await session.database.createReconciliationAdjustment(
            accountID: accountID,
            targetBalance: snapshot.clearedBalance + diff,
            now: now,
            transactionID: "adjustment"
        )
    }

    private static func finish(
        _ values: [String: Any],
        makeFixture: (String) throws -> URL
    ) async throws -> (locks: Int, threw: Bool) {
        let session = try open(
            rows: [[
                "id": "finish-cleared",
                "cleared": true,
                "amount": OracleJSON.int(values["clearedBalance"]) ?? 0,
                "date": "2026-09-14",
            ]],
            makeFixture: makeFixture
        )
        var threw = false
        do {
            _ = try await session.database.finishReconciliation(
                accountID: accountID,
                targetBalance: OracleJSON.int(values["reconcileAmount"]) ?? 0,
                now: now
            )
        } catch {
            threw = true
        }
        return (try lockedCount(session), threw)
    }

    /// Each seeded row's `reconciled` end state, by id (the fixture's `readback.after`).
    private static func reconciledFlags(_ session: Session, ids: Set<String>) throws -> OracleValue {
        let flags: [String: OracleValue] = try session.queue.read { db in
            var result: [String: OracleValue] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, reconciled FROM transactions WHERE tombstone = 0") {
                let id: String = row["id"]
                guard ids.contains(id) else {
                    continue
                }
                let reconciled: Int? = row["reconciled"]
                result[id] = .number(Double(reconciled ?? 0))
            }
            return result
        }
        return .object(flags)
    }

    /// Ids of the fixture rows and their embedded subtransactions, excluding the base fixture's own row.
    private static func seededIDs(_ rows: [[String: Any]]) -> Set<String> {
        Set(nonNullKeys(rows).keys)
    }

    private static func lockedCount(_ session: Session) throws -> Int {
        try session.queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transactions WHERE acct = ? AND reconciled = 1",
                arguments: [accountID]
            ) ?? 0
        }
    }

    // MARK: - Projections

    /// Live and tombstoned rows the adjustment write touched, read back from SQLite.
    private static func adjustmentRows(
        _ session: Session,
        _ write: AccountReconciliationDatabaseWrite
    ) throws -> (added: [OracleValue], deleted: [OracleValue]) {
        let ids = write.changed.transactions.sorted()
        let rows: [(row: OracleValue, tombstoned: Bool)] = try session.queue.read { db in
            try ids.compactMap { id in
                guard let row = try rowProjection(db, id: id) else {
                    return nil
                }
                return (row: row, tombstoned: isTombstoned(row))
            }
        }
        return (
            added: rows.filter { !$0.tombstoned }.map(\.row),
            deleted: rows.filter(\.tombstoned).map(\.row)
        )
    }

    /// Pending outbox cells for the transactions dataset, grouped into one object per row.
    private static func rowCells(_ session: Session) async throws -> OracleValue {
        let pending = try await session.database.pendingLocalSyncMessages(limit: 500)
        var rows: [String: [String: OracleValue]] = [:]
        for item in pending where item.message.dataset == "transactions" {
            let row = item.message.row
            var cells = rows[row, default: ["id": .string(row)]]
            cells[item.message.column] = ReplayNormalizer.parse(item.message.serializedValue)
            rows[row] = cells
        }
        return OracleValue.array(rows.values.map { OracleValue.object($0) }).sortedByID
    }

    private static func rowProjection(_ db: Database, id: String) throws -> OracleValue? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT id, acct, date, amount, category, description, notes, cleared, reconciled,
                   tombstone, is_parent, isChild, parent_id
            FROM transactions WHERE id = ?
            """, arguments: [id]) else {
            return nil
        }
        let date: Int? = row["date"]
        return .object([
            "id": cell(row, "id"),
            "account": cell(row, "acct"),
            "date": date.map { OracleValue.string(formatDay($0)) } ?? .null,
            "amount": cell(row, "amount"),
            "category": cell(row, "category"),
            "payee": cell(row, "description"),
            "notes": cell(row, "notes"),
            "cleared": cell(row, "cleared"),
            "reconciled": cell(row, "reconciled"),
            "tombstone": cell(row, "tombstone"),
            "isParent": cell(row, "is_parent"),
            "isChild": cell(row, "isChild"),
            "parentID": cell(row, "parent_id"),
            "children": .array([]),
        ])
    }

    private static func cell(_ row: Row, _ column: String) -> OracleValue {
        OracleValue.databaseValue(row[column])
    }

    private static func isTombstoned(_ row: OracleValue) -> Bool {
        guard case .object(let fields) = row else {
            return false
        }
        return fields["tombstone"] == .number(1)
    }

    // MARK: - Seeding

    private static func open(
        rows: [[String: Any]] = [],
        rules: [(conditions: String, actions: String)] = [],
        makeFixture: (String) throws -> URL
    ) throws -> Session {
        let url = try makeFixture(schemaSQL)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node1")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            for row in rows {
                try insert(row, parentID: nil, into: db)
            }
            for (index, rule) in rules.enumerated() {
                try db.execute(
                    sql: "INSERT INTO rules VALUES (?, ?, ?, 0)",
                    arguments: ["rule-\(index)", rule.conditions, rule.actions]
                )
            }
        }
        return Session(database: database, queue: queue)
    }

    /// Inserts one fixture row, then its embedded subtransactions with the row as their parent.
    private static func insert(_ row: [String: Any], parentID: String?, into db: Database) throws {
        let id = row["id"] as? String ?? ""
        try db.execute(
            sql: """
                INSERT INTO transactions
                    (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                     description, notes, cleared, isChild, reconciled, transferred_id)
                VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, NULL)
                """,
            arguments: [
                id,
                row["account"] as? String ?? accountID,
                day(row["date"] as? String),
                OracleJSON.int(row["amount"]) ?? 0,
                row["category"] as? String,
                row["parent_id"] as? String ?? parentID,
                flag(row["is_parent"]),
                row["payee"] as? String,
                row["notes"] as? String,
                flag(row["cleared"]),
                flag(row["is_child"]),
                flag(row["reconciled"]),
            ]
        )
        for child in (row["subtransactions"] as? [[String: Any]]) ?? [] {
            try insert(child, parentID: id, into: db)
        }
    }

    private static func day(_ text: String?) -> Int {
        Int((text ?? "2026-09-14").replacingOccurrences(of: "-", with: "")) ?? 20_260_914
    }

    private static func formatDay(_ day: Int) -> String {
        let text = String(day)
        return "\(text.prefix(4))-\(text.dropFirst(4).prefix(2))-\(text.suffix(2))"
    }

    private static func flag(_ value: Any?) -> Int {
        (value as? Bool) == true ? 1 : 0
    }

    private static func jsonText(_ value: Any?) throws -> String {
        guard let value else {
            throw OracleReplayError.malformedFixture("rule is missing a JSON array")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}
