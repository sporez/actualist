import Foundation
import GRDB

extension BudgetDatabase {
    static let messagesTimestampIndexName = "actualist_messages_crdt_timestamp"

    /// `since`, merkle rebuilds and `MAX(timestamp)` scan `messages_crdt` by
    /// timestamp alone, and Actual's own `messages_crdt_search` index leads with
    /// `dataset`. Added here, not to the generated starter schema, so it also
    /// reaches imported and previously created files. `IF NOT EXISTS` makes
    /// every open idempotent and needs no migration marker.
    static func prepareMessagesTimestampIndex(in queue: DatabaseQueue) throws {
        try queue.write { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'messages_crdt')"
            ) ?? false else {
                return
            }
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS \(messagesTimestampIndexName)
                ON messages_crdt(timestamp)
                """)
        }
    }
}
