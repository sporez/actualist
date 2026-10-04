import GRDB

/// The CRDT message count and newest timestamp that identify a budget's synced
/// state for review guards (Hold and Template reviews). A missing
/// `messages_crdt` table reads as an empty watermark.
struct CRDTMessageWatermark: Equatable, Sendable {
    let messageCount: Int
    let maxMessageTimestamp: String?
}

extension BudgetDatabase {
    func crdtMessageWatermark(db: Database) throws -> CRDTMessageWatermark {
        guard try tableExists("messages_crdt", db: db) else {
            return CRDTMessageWatermark(messageCount: 0, maxMessageTimestamp: nil)
        }
        let row = try Row.fetchOne(
            db,
            sql: "SELECT COUNT(*) AS message_count, MAX(timestamp) AS max_timestamp FROM messages_crdt"
        )
        return CRDTMessageWatermark(
            messageCount: row?["message_count"] ?? 0,
            maxMessageTimestamp: row?["max_timestamp"]
        )
    }
}
