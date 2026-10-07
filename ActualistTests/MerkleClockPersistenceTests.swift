import Foundation
import GRDB
import Testing
@testable import Actualist

/// `messages_clock` upkeep (audit 2.8, stage 1): upstream's JSON shape, one
/// rebuild per file, and the single `insertCRDTMessage` choke point.
@MainActor
@Suite("Merkle clock persistence")
struct MerkleClockPersistenceTests {
    private let support = LocalFirstActualStoreTests()
    private let t1 = "2026-07-04T12:00:00.000Z-0000-node1"
    private let t2 = "2026-07-04T12:01:00.000Z-0000-node1"
    private let t3 = "2026-07-04T12:02:00.000Z-000a-node2"

    private func message(_ timestamp: String, _ value: String = "S:v") -> ActualSyncDecodedMessage {
        ActualSyncDecodedMessage(
            timestamp: timestamp, dataset: "transactions", row: "txn", column: "category", serializedValue: value
        )
    }

    private func clockText(_ url: URL) throws -> String? {
        try DatabaseQueue(path: url.path).read {
            try String.fetchOne($0, sql: "SELECT clock FROM messages_clock")
        }
    }

    private func count(_ sql: String, _ url: URL) throws -> Int? {
        try DatabaseQueue(path: url.path).read { try Int.fetchOne($0, sql: sql) }
    }

    private func run(_ sql: String, _ url: URL) throws {
        try DatabaseQueue(path: url.path).write { try $0.execute(sql: sql) }
    }

    private func storedTrie(_ url: URL) throws -> MerkleTrie? {
        let text = try #require(try clockText(url))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return MerkleTrie(jsonObject: try #require(object["merkle"]))
    }

    private func expectedTrie(_ timestamps: [String]) -> MerkleTrie {
        var trie = MerkleTrie()
        for timestamp in timestamps { trie.insert(SyncTimestamp.parse(timestamp)!) }
        return trie.pruned()
    }

    @Test func remoteBatchWritesUpstreamShapeAndSurvivesReopen() async throws {
        let url = try support.makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")
        _ = try await database.applyRemoteSyncMessages([message(t1), message(t2), message(t3, "S:w")])

        let text = try #require(try clockText(url))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["timestamp", "merkle"])
        #expect(SyncTimestamp.parse(try #require(object["timestamp"] as? String)) != nil)
        let expected = expectedTrie([t1, t2, t3])
        let stored = try storedTrie(url)?.jsonString
        #expect(stored == expected.jsonString, "stored=\(stored ?? "nil") expected=\(expected.jsonString)")

        let reopened = try BudgetDatabase(databaseURL: url, localNodeID: "node")
        #expect(try await reopened.merkleDivergence(from: expected) == nil)
        _ = try await reopened.applyRemoteSyncMessages([message("2026-07-04T12:03:00.000Z-0000-node1", "S:z")])
        #expect(try storedTrie(url)?.hash != expected.hash)
    }

    @Test func exactDuplicateIsNeverXoredTwice() async throws {
        let url = try support.makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")
        _ = try await database.applyRemoteSyncMessages([message(t1)])
        _ = try await database.applyRemoteSyncMessages([message(t1)])
        let stored = try storedTrie(url)?.jsonString
        #expect(stored == expectedTrie([t1]).jsonString, "stored=\(stored ?? "nil") expected=\(expectedTrie([t1]).jsonString)")
    }

    @Test func importedClockIsNotTrustedAndRebuildsFromTheMessageLogOnce() async throws {
        let url = try support.makeSQLiteFixture(extraSQL: """
            INSERT INTO messages_crdt VALUES ('\(t1)', 'transactions', 'txn', 'category', 'S:a');
            INSERT INTO messages_crdt VALUES ('\(t2)', 'transactions', 'txn', 'category', 'S:b');
            CREATE TABLE messages_clock (id INTEGER PRIMARY KEY, clock TEXT);
            INSERT INTO messages_clock VALUES (1, '{"timestamp":"2026-07-04T12:09:00.000Z-0003-abcdef0123456789","merkle":{"hash":777}}');
            """)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")

        // Opening does not rebuild (F-8): the stored clock and marker are untouched until first use.
        #expect(try storedTrie(url)?.hash == 777)
        #expect(try count("SELECT COUNT(*) FROM actualist_local_migrations WHERE name = 'merkle-v1'", url) == 0)

        #expect(try await database.merkleDivergence(from: expectedTrie([t1, t2])) == nil)
        #expect(try storedTrie(url) == expectedTrie([t1, t2]))
        let text = try #require(try clockText(url))
        #expect(text.contains("2026-07-04T12:09:00.000Z-0003-abcdef0123456789"))
        let marker = try count("SELECT COUNT(*) FROM actualist_local_migrations WHERE name = 'merkle-v1'", url)
        #expect(marker == 1)

        // A second open does not rebuild: a clock written since is kept.
        try run("UPDATE messages_clock SET clock = '{\"timestamp\":\"2026-07-04T12:09:00.000Z-0003-abcdef0123456789\",\"merkle\":{\"hash\":5}}'", url)
        let reopened = try BudgetDatabase(databaseURL: url, localNodeID: "node")
        _ = try await reopened.merkleDivergence(from: expectedTrie([t1, t2]))
        #expect(try storedTrie(url)?.hash == 5)
    }

    @Test func firstLocalWriteRebuildsAnUntrustedImportedClockOnce() async throws {
        let url = try support.makeSQLiteFixture(extraSQL: """
            INSERT INTO messages_crdt VALUES ('\(t1)', 'transactions', 'txn', 'category', 'S:a');
            CREATE TABLE messages_clock (id INTEGER PRIMARY KEY, clock TEXT);
            INSERT INTO messages_clock VALUES (1, '{"timestamp":"2026-07-04T12:09:00.000Z-0003-abcdef0123456789","merkle":{"hash":777}}');
            """)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")
        #expect(try count("SELECT COUNT(*) FROM actualist_local_migrations WHERE name = 'merkle-v1'", url) == 0)

        _ = try await database.applyRemoteSyncMessages([message(t2, "S:b")])
        #expect(try storedTrie(url) == expectedTrie([t1, t2]))
        #expect(try count("SELECT COUNT(*) FROM actualist_local_migrations WHERE name = 'merkle-v1'", url) == 1)
    }

    @Test func rebuildFromTheLogEqualsIncrementalInserts() async throws {
        let incrementalURL = try support.makeSQLiteFixture()
        let incremental = try BudgetDatabase(databaseURL: incrementalURL, localNodeID: "node")
        _ = try await incremental.applyRemoteSyncMessages([message(t1), message(t2, "S:b"), message(t3, "S:c")])
        let incrementalTrie = try #require(try storedTrie(incrementalURL))

        let rebuiltURL = try support.makeSQLiteFixture(extraSQL: """
            INSERT INTO messages_crdt VALUES ('\(t1)', 'transactions', 'txn', 'category', 'S:v');
            INSERT INTO messages_crdt VALUES ('\(t2)', 'transactions', 'txn', 'category', 'S:b');
            INSERT INTO messages_crdt VALUES ('\(t3)', 'transactions', 'txn', 'category', 'S:c');
            """)
        let rebuilt = try BudgetDatabase(databaseURL: rebuiltURL, localNodeID: "node")
        _ = try await rebuilt.merkleDivergence(from: incrementalTrie)
        let stored = try storedTrie(rebuiltURL)?.jsonString
        #expect(stored == incrementalTrie.jsonString, "rebuilt=\(stored ?? "nil") incremental=\(incrementalTrie.jsonString)")
    }

    @Test func localCommitUpdatesTheTrieAndRolledBackWritesDoNot() async throws {
        let url = try support.makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node")
        _ = try await database.applyRemoteSyncMessages([message(t1)])
        let before = try storedTrie(url)

        _ = try await database.commitLocalSyncMessagesAndEnqueue([
            ActualSyncDecodedMessage(
                timestamp: "pending", dataset: "transactions", row: "txn", column: "category",
                serializedValue: "S:local"
            )
        ])
        let afterCommit = try #require(try storedTrie(url))
        #expect(afterCommit.hash != before?.hash)

        await #expect(throws: (any Error).self) {
            _ = try await database.commitLocalSyncMessagesAndEnqueue([
                ActualSyncDecodedMessage(
                    timestamp: "pending", dataset: "no_such_table", row: "r", column: "c", serializedValue: "S:x"
                )
            ])
        }
        #expect(try storedTrie(url) == afterCommit)
        #expect(try await database.merkleDivergence(from: afterCommit) == nil)
    }
}
