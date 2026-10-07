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

extension BudgetDatabase {
    /// Concurrency 5.2b (audit CA-12): two gestures that each decided to create
    /// the same new payee name must not both create it. Runs inside the write
    /// transaction; when a live non-transfer payee with that name now exists,
    /// the gesture uses it and drops its own creation messages.
    func settlePayeeCreation(
        resolvedPayeeID: String?,
        creation: PendingPayeeCreation?,
        db: Database
    ) throws -> SettledPayee {
        guard let creation else {
            return SettledPayee(payeeID: resolvedPayeeID, creationMessages: [], createdPayeeID: nil)
        }
        if let existingID = try liveTransferlessPayeeID(named: creation.name, db: db) {
            return SettledPayee(payeeID: existingID, creationMessages: [], createdPayeeID: nil)
        }
        return SettledPayee(
            payeeID: creation.payeeID,
            creationMessages: creation.messages,
            createdPayeeID: creation.payeeID
        )
    }

    private func liveTransferlessPayeeID(named name: String, db: Database) throws -> String? {
        guard try tableExists("payees", db: db) else { return nil }
        let columns = try columnSet(for: "payees", db: db)
        let transfer = column("transfer_acct", fallback: "NULL", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, \(transfer) AS transfer_acct FROM payees
                WHERE \(predicateForLiveRows(columns: columns))
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
}
