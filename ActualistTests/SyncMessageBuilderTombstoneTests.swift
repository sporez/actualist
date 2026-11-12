import Testing
@testable import Actualist

struct SyncMessageBuilderTombstoneTests {
    @Test func tombstoneAndReviveMatchTheHandWrittenMessages() throws {
        var helper = LocalFirstSyncMessageBuilder()
        var manual = LocalFirstSyncMessageBuilder()

        let deleted = try helper.tombstone(dataset: "payees", row: "payee-1")
        let revived = try helper.revive(dataset: "rules", row: "rule-1")

        let expectedDeleted = try manual.makeMessage(
            dataset: "payees", row: "payee-1", column: "tombstone", value: .bool(true)
        )
        let expectedRevived = try manual.makeMessage(
            dataset: "rules", row: "rule-1", column: "tombstone", value: .bool(false)
        )
        #expect(deleted == expectedDeleted)
        #expect(revived == expectedRevived)
        #expect(deleted.column == "tombstone")
        // Actual stores a boolean as the integer 1 or 0.
        #expect(deleted.serializedValue == "N:1")
        #expect(revived.serializedValue == "N:0")
        // Each call takes the next pending timestamp, like `makeMessage`.
        #expect(deleted.timestamp != revived.timestamp)
    }
}
