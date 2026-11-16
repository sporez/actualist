import Foundation
import GRDB

/// A payee a gesture decided to create by name before its write transaction.
struct PendingPayeeCreation: Sendable {
    let payeeID: String
    let name: String
    let messages: [ActualSyncDecodedMessage]
}

/// The payee a gesture settled on at commit time.
struct SettledPayee: Sendable {
    let payeeID: String?
    /// Creation messages to commit; empty when another writer created the name first.
    let creationMessages: [ActualSyncDecodedMessage]
    /// The id to record as created by this gesture, if it still creates one.
    let createdPayeeID: String?
}

enum PayeeSQL {
    static func fetchPayees(orderedForPicker: Bool = true, in database: isolated BudgetDatabase) throws -> [ActualPayee] {
        try database.queue.read { db in
            guard try database.tableExists("payees", db: db) else {
                return []
            }

            let columns = try database.columnSet(for: "payees", db: db)
            let category = database.column("category", fallback: "NULL", columns: columns)
            let transferAccount = database.column("transfer_acct", fallback: "NULL", columns: columns)
            let favorite = database.column("favorite", fallback: "0", columns: columns)
            let sql = """
                SELECT id, name, \(category) AS category, \(transferAccount) AS transfer_acct,
                       \(favorite) AS favorite
                FROM payees
                WHERE \(database.predicateForLiveRows(columns: columns))
                """
            let payees = try Row.fetchAll(db, sql: sql).map { row in
                (
                    payee: ActualPayee(
                    id: row["id"],
                    name: row["name"] ?? "",
                    category: row["category"],
                    transferAccount: row["transfer_acct"]
                    ),
                    favorite: SQLiteValueCoercion.lenientBool(row["favorite"])
                )
            }
            guard orderedForPicker else { return payees.map(\.payee) }
            let recentRanks = try recentCommonPayeeRanks(in: database, db: db)
            return payees.sorted { lhs, rhs in
                if lhs.payee.transferAccount != nil || rhs.payee.transferAccount != nil {
                    if (lhs.payee.transferAccount != nil) != (rhs.payee.transferAccount != nil) {
                        return lhs.payee.transferAccount == nil
                    }
                }
                if lhs.favorite != rhs.favorite {
                    return lhs.favorite
                }
                let lhsRank = lhs.payee.id.flatMap { recentRanks[$0] }
                let rhsRank = rhs.payee.id.flatMap { recentRanks[$0] }
                if lhsRank != rhsRank {
                    if let lhsRank, let rhsRank { return lhsRank < rhsRank }
                    return lhsRank != nil
                }
                return lhs.payee.name.localizedCaseInsensitiveCompare(rhs.payee.name) == .orderedAscending
            }
            .map(\.payee)
        }
    }

    /// Common payees count transactions after 12 weeks (84 days) before the
    /// local day (`getCommonPayees`, db/index.ts).
    static func recentPayeeCutoff(now: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let today = ActualDateOnly.today(now: now, timeZone: timeZone)
        return ActualDateOnly.shiftedDayID(today, byDays: -84) ?? today
    }

    private static func recentCommonPayeeRanks(in database: isolated BudgetDatabase, db: Database) throws -> [String: Int] {
        guard try database.tableExists("transactions", db: db) else { return [:] }
        let transactionColumns = try database.columnSet(for: "transactions", db: db)
        guard transactionColumns.contains("date"),
              let payeeColumn = TransactionRowColumns.payee(in: transactionColumns) else {
            return [:]
        }
        let rawPayee = "t.\(database.quotedIdentifier(payeeColumn))"
        var resolvedPayee = rawPayee
        var mappingJoin = ""
        if try database.tableExists("payee_mapping", db: db) {
            let mappingColumns = try database.columnSet(for: "payee_mapping", db: db)
            let target = mappingColumns.contains("targetId") ? "targetId" : mappingColumns.contains("target_id") ? "target_id" : nil
            if mappingColumns.contains("id"), let target {
                mappingJoin = "LEFT JOIN payee_mapping pm ON pm.id = \(rawPayee)"
                resolvedPayee = "COALESCE(pm.\(database.quotedIdentifier(target)), \(rawPayee))"
            }
        }
        let liveTransactions = database.predicateForLiveRows(columns: transactionColumns, tableAlias: "t")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(resolvedPayee) AS payee_id, COUNT(*) AS usage_count
                FROM transactions t
                \(mappingJoin)
                WHERE \(liveTransactions)
                  AND \(database.normalizedDateExpression("t.\(database.quotedIdentifier("date"))")) > ?
                  AND \(rawPayee) IS NOT NULL
                GROUP BY \(resolvedPayee)
                ORDER BY usage_count DESC, payee_id
                LIMIT 10
                """,
            arguments: [Self.recentPayeeCutoff()]
        )
        return Dictionary(uniqueKeysWithValues: rows.enumerated().compactMap { index, row in
            guard let id = row["payee_id"] as String? else { return nil }
            return (id, index)
        })
    }

    /// Concurrency 5.2b (audit CA-12): two gestures that each decided to create
    /// the same new payee name must not both create it. Runs inside the write
    /// transaction; when a live non-transfer payee with that name now exists,
    /// the gesture uses it and drops its own creation messages.
    static func settlePayeeCreation(
        resolvedPayeeID: String?,
        creation: PendingPayeeCreation?,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> SettledPayee {
        guard let creation else {
            return SettledPayee(payeeID: resolvedPayeeID, creationMessages: [], createdPayeeID: nil)
        }
        if let existingID = try liveTransferlessPayeeID(named: creation.name, in: database, db: db) {
            return SettledPayee(payeeID: existingID, creationMessages: [], createdPayeeID: nil)
        }
        return SettledPayee(
            payeeID: creation.payeeID,
            creationMessages: creation.messages,
            createdPayeeID: creation.payeeID
        )
    }

    private static func liveTransferlessPayeeID(named name: String, in database: isolated BudgetDatabase, db: Database) throws -> String? {
        guard try database.tableExists("payees", db: db) else { return nil }
        let columns = try database.columnSet(for: "payees", db: db)
        let transfer = database.column("transfer_acct", fallback: "NULL", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, \(transfer) AS transfer_acct FROM payees
                WHERE \(database.predicateForLiveRows(columns: columns))
                """
        )
        for row in rows {
            guard (row["transfer_acct"] as String?) == nil,
                  let id = row["id"] as String?, !id.isEmpty,
                  let existingName = row["name"] as String?,
                  existingName.caseInsensitiveCompare(name) == .orderedSame else { continue }
            return id
        }
        return nil
    }

    /// Re-points a transaction's payee after `settlePayeeCreation` picked an
    /// existing payee instead of the one the messages were built for.
    static func retargetingPayee(
        _ messages: [ActualSyncDecodedMessage],
        from builtFor: String,
        to settled: String
    ) -> [ActualSyncDecodedMessage] {
        guard builtFor != settled else { return messages }
        return messages.map { message in
            guard message.dataset == "transactions",
                  message.column == "description",
                  message.serializedValue == "S:\(builtFor)" else { return message }
            return ActualSyncDecodedMessage(
                timestamp: message.timestamp,
                dataset: message.dataset,
                row: message.row,
                column: message.column,
                serializedValue: "S:\(settled)"
            )
        }
    }

    /// Display names for review rows, read in the review's own transaction.
    /// Follows the feed: a merged payee resolves through `payee_mapping`, and a
    /// transfer payee with no name reads as its counterpart account. A missing
    /// entry means the caller keeps its generic row title.
    static func reviewPayeeNames(
        payeeIDs: some Sequence<String?>,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [String: String] {
        let ids = Set(payeeIDs.compactMap { $0 }.filter { !$0.isEmpty })
        guard !ids.isEmpty, try database.tableExists("payees", db: db) else { return [:] }
        let payeeColumns = try database.columnSet(for: "payees", db: db)
        guard payeeColumns.contains("id"), payeeColumns.contains("name") else { return [:] }
        let transferColumn = ["transfer_acct", "transfer_account"].first(where: payeeColumns.contains)
        var hasAccounts = false
        if try database.tableExists("accounts", db: db) {
            hasAccounts = try database.columnSet(for: "accounts", db: db).isSuperset(of: ["id", "name"])
        }
        let targets = try RuleSQL.payeeMappingTargets(in: database, db: db)
        let transferSelect = transferColumn.map { ", \(database.quotedIdentifier($0)) AS transfer" } ?? ""

        var names: [String: String] = [:]
        for id in ids {
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT name\(transferSelect) FROM payees WHERE id = ?",
                arguments: [targets[id] ?? id]
            ) else { continue }
            if let name = (row["name"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                names[id] = name
            } else if hasAccounts, transferColumn != nil,
                      let accountID = row["transfer"] as String?, !accountID.isEmpty,
                      let accountName = try String.fetchOne(
                          db, sql: "SELECT name FROM accounts WHERE id = ?", arguments: [accountID]
                      ), !accountName.isEmpty {
                names[id] = accountName
            }
        }
        return names
    }
}
