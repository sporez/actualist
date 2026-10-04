import Foundation
import Testing
@testable import Actualist

/// Replays `packages/crdt/src/crdt/merkle.test.ts` (pinned Actual v26.9.0) against
/// the Swift port, plus the normalization rule from `timestamp.ts`.
struct MerkleTrieTests {
    private static func minute(_ timestamp: String) -> Int64 {
        SyncTimestamp.parse(timestamp)!.milliseconds / 60_000
    }

    private static func trie(_ entries: [(String, Int32)], into start: MerkleTrie = .empty) -> MerkleTrie {
        var trie = start
        for (timestamp, hash) in entries {
            trie.insert(minute: minute(timestamp), hash: hash)
        }
        return trie
    }

    private static func iso(_ milliseconds: Int64?) -> String? {
        milliseconds.map { SyncTimestamp.wallTimeString(for: Date(timeIntervalSince1970: Double($0) / 1_000)) }
    }

    private static let node = "0123456789ABCDEF"

    @Test func realTimestampsHashLikeUpstreamAndMatchTheSnapshotRoot() {
        let first = SyncTimestamp.parse("2018-11-12T13:21:40.122Z-0000-\(Self.node)")!
        let second = SyncTimestamp.parse("2018-11-13T13:21:40.122Z-0000-\(Self.node)")!
        #expect(MerkleHash.hash(of: first) == 1_983_295_247)
        #expect(MerkleHash.hash(of: second) == 1_469_038_940)

        var trie = MerkleTrie()
        trie.insert(first)
        trie.insert(second)
        #expect(trie.hash == 565_800_531)
    }

    @Test func hashUsesTheNormalizedTimestampNotTheStoredText() {
        let stored = SyncTimestamp.parse("2018-11-12T13:21:40.122Z-00ab-node1")!
        let canonical = "2018-11-12T13:21:40.122Z-00AB-00000000000node1"
        #expect(MerkleHash.canonical(stored) == canonical)
        #expect(MerkleHash.hash(of: stored) == MerkleHash.hash(canonical))
        #expect(MerkleHash.hash(of: stored) != MerkleHash.hash("2018-11-12T13:21:40.122Z-00ab-node1"))
    }

    @Test func diffReturnsTheCorrectTimeDifference() {
        let messages: [(String, Int32)] = [
            ("2018-11-13T13:20:40.122Z-0000-\(Self.node)", 1000),
            ("2018-11-14T13:05:35.122Z-0000-\(Self.node)", 1100),
            ("2018-11-15T22:19:00.122Z-0000-\(Self.node)", 1200),
            ("2018-11-20T13:19:40.122Z-0000-\(Self.node)", 1300),
            ("2018-11-25T13:19:40.122Z-0000-\(Self.node)", 1400)
        ]
        var trie1 = Self.trie(Array(messages[0...2]))
        var trie2 = Self.trie(Array(messages[3...4]))
        #expect(trie1.hash == 788)
        #expect(trie2.hash == 108)
        #expect(Self.iso(MerkleTrie.diff(trie1, trie2)) == "2018-11-02T17:15:00.000Z")

        trie1 = Self.trie(Array(messages[3...4]), into: trie1)
        trie2 = Self.trie(Array(messages[0...2]), into: trie2)
        #expect(trie1.hash == 888)
        #expect(trie1.hash == trie2.hash)
        #expect(MerkleTrie.diff(trie1, trie2) == nil)
    }

    @Test func diffingAnEmptyTrieReturnsZero() {
        var populated = MerkleTrie()
        populated.insert(SyncTimestamp.parse("2009-01-02T10:17:37.789Z-0000-0000testinguuid1")!)
        #expect(MerkleTrie.diff(.empty, populated) == 0)
        #expect(MerkleTrie.diff(populated, .empty) == 0)
    }

    private static let pruneMessages: [(String, Int32)] = [
        ("2018-11-01T01:00:00.000Z-0000-\(node)", 1000), ("2018-11-01T01:09:00.000Z-0000-\(node)", 1100),
        ("2018-11-01T01:18:00.000Z-0000-\(node)", 1200), ("2018-11-01T01:27:00.000Z-0000-\(node)", 1300),
        ("2018-11-01T01:36:00.000Z-0000-\(node)", 1400), ("2018-11-01T01:45:00.000Z-0000-\(node)", 1500),
        ("2018-11-01T01:54:00.000Z-0000-\(node)", 1600), ("2018-11-01T02:03:00.000Z-0000-\(node)", 1700),
        ("2018-11-01T02:10:00.000Z-0000-\(node)", 1800), ("2018-11-01T02:19:00.000Z-0000-\(node)", 1900),
        ("2018-11-01T02:28:00.000Z-0000-\(node)", 2000), ("2018-11-01T02:37:00.000Z-0000-\(node)", 2100)
    ]

    @Test func pruningKeepsTheRootHashAndTheLastTwoKeysPerLevel() {
        let trie = Self.trie(Self.pruneMessages)
        #expect(trie.hash == 2496)
        let pruned = trie.pruned()
        #expect(pruned.hash == 2496)
        #expect(pruned != trie)
        #expect(pruned.pruned() == pruned)
        // Upstream never prunes a node whose hash is 0.
        #expect(MerkleTrie.empty.pruned() == .empty)
    }

    @Test func diffingDifferentlyShapedTriesMatchesUpstream() {
        let trie = Self.trie(Self.pruneMessages)
        #expect(Self.iso(MerkleTrie.diff(.empty, trie)) == "1970-01-01T00:00:00.000Z")
        #expect(Self.iso(MerkleTrie.diff(trie, .empty)) == "1970-01-01T00:00:00.000Z")

        let older = ("2018-11-01T00:59:00.000Z-0000-\(Self.node)", Int32(900))
        let trie1 = Self.trie([older], into: trie)
        #expect(Self.iso(MerkleTrie.diff(trie1, trie)) == "2018-11-01T00:54:00.000Z")
        #expect(Self.iso(MerkleTrie.diff(trie1.pruned(), trie)) == "2018-11-01T00:45:00.000Z")
        #expect(Self.iso(MerkleTrie.diff(trie1, trie.pruned())) == "2018-11-01T00:45:00.000Z")
        #expect(Self.iso(MerkleTrie.diff(trie1.pruned(), trie.pruned())) == "2018-11-01T00:45:00.000Z")

        let trie2 = Self.trie([older, ("2018-11-01T01:15:00.000Z-0000-\(Self.node)", 1422)], into: trie)
        #expect(Self.iso(MerkleTrie.diff(trie2, trie)) == "2018-11-01T00:54:00.000Z")
        #expect(Self.iso(MerkleTrie.diff(trie2.pruned(), trie)) == "2018-11-01T00:45:00.000Z")
        #expect(Self.iso(MerkleTrie.diff(trie2, trie.pruned())) == "2018-11-01T00:45:00.000Z")
        #expect(Self.iso(MerkleTrie.diff(trie2.pruned(), trie.pruned())) == "2018-11-01T01:12:00.000Z")
    }

    @Test func jsonRoundTripsInUpstreamShapeAndTruncatesToInt32() throws {
        let trie = Self.trie(Self.pruneMessages).pruned()
        #expect(MerkleTrie(jsonString: trie.jsonString) == trie)
        #expect(trie.jsonString.contains("\"hash\":2496"))

        let wide = try #require(MerkleTrie(jsonString: "{\"hash\":4294967297,\"1\":{\"hash\":-5}}"))
        #expect(wide.hash == 1)
        #expect(MerkleTrie(jsonString: "{}") == .empty)
    }

    @Test(arguments: ["", "not json", "[]", "{\"hash\":\"1\"}", "{\"0\":5}", "{\"hash\":true}"])
    func unreadableMerkleJSONIsNil(_ text: String) {
        #expect(MerkleTrie(jsonString: text) == nil)
    }

    @Test func absurdlyDeepJSONIsRejected() {
        var text = "{\"hash\":1}"
        for _ in 0..<40 { text = "{\"hash\":1,\"0\":\(text)}" }
        #expect(MerkleTrie(jsonString: text) == nil)
    }
}
