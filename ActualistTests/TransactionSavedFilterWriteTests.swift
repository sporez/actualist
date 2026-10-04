import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct TransactionSavedFilterWriteTests {
    private let support = LocalFirstActualStoreTests()

    @Test func nameOnlyUpdatePreservesConditionBytesAndUnchangedUpdateIsNoOp() async throws {
        let raw = #"[{"field":"account","op":"oneOf","value":["b","a"],"type":"id"}]"#
        let url = try fixture(filterRows: "INSERT INTO transaction_filters VALUES ('filter-1', 'Old', '\(raw)', 'and', 0);")
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "savedfilternode")

        var builder = LocalFirstSyncMessageBuilder()
        let renamed = try await database.updateSavedTransactionFilter(
            SavedTransactionFilterUpdate(filterID: "filter-1", name: "New", conditions: nil, join: nil),
            builder: &builder
        )
        #expect(renamed.changed)
        #expect(try savedFilterRow("filter-1", at: url).name == "New")
        #expect(try savedFilterRow("filter-1", at: url).conditions == raw)
        let emitted = try support.storedCRDTMessages(at: url)
        #expect(emitted.map(\.column) == ["name"])

        let clockBefore = await database.localClock
        let pendingBefore = try await database.pendingLocalSyncMessageCount()
        var noOpBuilder = LocalFirstSyncMessageBuilder()
        let unchanged = try await database.updateSavedTransactionFilter(
            SavedTransactionFilterUpdate(filterID: "filter-1", name: "New", conditions: nil, join: nil),
            builder: &noOpBuilder
        )
        #expect(!unchanged.changed)
        #expect(await database.localClock == clockBefore)
        #expect(try await database.pendingLocalSyncMessageCount() == pendingBefore)
        #expect(try support.storedCRDTMessages(at: url).count == 1)
    }

    @Test func duplicateNamePrecedesEquivalentConditionsAndUpdateRejectsLivePeer() async throws {
        let raw = #"[{"field":"account","op":"is","value":"checking","type":"id"}]"#
        let url = try fixture(filterRows: """
            INSERT INTO transaction_filters VALUES ('aSelf', 'Self', '\(raw)', 'and', 0);
            INSERT INTO transaction_filters VALUES ('zPeer', 'Peer', '\(raw)', 'and', 0);
            """)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "savedfilternode")
        let condition = RuleCondition(field: "account", operation: "is", value: .string("checking"), type: "id")

        do {
            var builder = LocalFirstSyncMessageBuilder()
            _ = try await database.updateSavedTransactionFilter(
                SavedTransactionFilterUpdate(filterID: "aSelf", name: "Peer", conditions: [condition], join: .and),
                builder: &builder
            )
            Issue.record("Duplicate names must be rejected before condition equivalence")
        } catch {
            #expect(error.localizedDescription.contains("already a saved filter named Peer"))
        }

        do {
            var builder = LocalFirstSyncMessageBuilder()
            _ = try await database.updateSavedTransactionFilter(
                SavedTransactionFilterUpdate(filterID: "aSelf", name: "Self", conditions: [condition], join: .and),
                builder: &builder
            )
            Issue.record("An equivalent live peer must be rejected while self is excluded")
        } catch {
            #expect(error.localizedDescription.contains("already saved as Peer"))
        }
        #expect(try support.storedCRDTMessages(at: url).isEmpty)
        #expect(try savedFilterRow("aSelf", at: url).name == "Self")
        #expect(try savedFilterRow("zPeer", at: url).name == "Peer")
    }

    @Test func createAllowsSupportedMultiIDArrayEvenWhenPeerHasSameValues() async throws {
        let raw = #"[{"field":"account","op":"oneOf","value":["acct-a","acct-b"],"type":"id"}]"#
        let url = try fixture(filterRows: "INSERT INTO transaction_filters VALUES ('existing', 'Existing', '\(raw)', 'and', 0);")
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "savedfilternode")
        let condition = RuleCondition(
            field: "account",
            operation: "oneOf",
            value: .array([.string("acct-a"), .string("acct-b")]),
            type: "id"
        )

        var builder = LocalFirstSyncMessageBuilder()
        let created = try await database.createSavedTransactionFilter(
            id: "created",
            draft: SavedTransactionFilterDraft(name: "Another name", conditions: [condition], join: .and),
            builder: &builder
        )
        #expect(created.changed)
        #expect(try savedFilterRow("created", at: url).name == "Another name")
        #expect(try savedFilterRow("created", at: url).conditions != nil)
        #expect(try await database.pendingLocalSyncMessageCount() == 4)
    }

    @Test func deleteTombstonesUnsupportedFilterWithoutRewritingItsRawConditions() async throws {
        let raw = #"[{"field":"future_condition","op":"is","value":{"opaque":true}}]"#
        let url = try fixture(filterRows: "INSERT INTO transaction_filters VALUES ('unsupported', 'Future', '\(raw)', 'and', 0);")
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "savedfilternode")
        var builder = LocalFirstSyncMessageBuilder()
        #expect(try await database.deleteSavedTransactionFilter(id: "unsupported", builder: &builder).changed)
        #expect(try savedFilterRow("unsupported", at: url).conditions == raw)
        #expect(try savedFilterRow("unsupported", at: url).tombstone == 1)
        #expect(try support.storedCRDTMessages(at: url).map(\.column) == ["tombstone"])
    }

    @Test func deleteTreatsNullTombstoneAsLive() async throws {
        let raw = #"[{"field":"amount","op":"gt","value":100}]"#
        let url = try fixture(filterRows: "INSERT INTO transaction_filters VALUES ('null-tombstone', 'Legacy', '\(raw)', 'and', NULL);")
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "savedfilternode")
        var builder = LocalFirstSyncMessageBuilder()
        #expect(try await database.deleteSavedTransactionFilter(id: "null-tombstone", builder: &builder).changed)
        #expect(try savedFilterRow("null-tombstone", at: url).tombstone == 1)
    }

    private func fixture(filterRows: String) throws -> URL {
        try support.makeSQLiteFixture(extraSQL: """
            CREATE TABLE transaction_filters (
                id TEXT PRIMARY KEY, name TEXT, conditions TEXT, conditions_op TEXT, tombstone INTEGER
            );
            \(filterRows)
            """)
    }

    private func savedFilterRow(_ id: String, at url: URL) throws -> (name: String?, conditions: String?, tombstone: Int?) {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.readSync { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT name, conditions, tombstone FROM transaction_filters WHERE id = ?",
                arguments: [id]
            ) else { return (nil, nil, nil) }
            return (row["name"], row["conditions"], row["tombstone"])
        }
    }
}
