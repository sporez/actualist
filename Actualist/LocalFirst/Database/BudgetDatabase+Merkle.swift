import Foundation
import GRDB

/// Persistence and maintenance of Actual's merkle trie in `messages_clock`.
///
/// `insertCRDTMessage` is the single choke point. Inserts stage into a working
/// trie, `writeTrackingMerkle` prunes and persists it in the same SQLite
/// transaction, and the in-memory cache is replaced only after that transaction
/// commits. A rolled-back write therefore leaves both table and cache untouched.
extension BudgetDatabase {
    static let merkleRebuildMigration = "merkle-v1"

    /// Runs a write transaction that may insert into `messages_crdt`.
    func writeTrackingMerkle<T>(_ body: (Database) throws -> T) throws -> T {
        merkleWorking = nil
        merkleStaged = nil
        defer {
            merkleWorking = nil
            merkleStaged = nil
        }
        let result = try queue.write { db in
            let result = try body(db)
            try finishMerkleBatch(db)
            return result
        }
        if let staged = merkleStaged {
            merkleCache = staged
        }
        return result
    }

    func recordMerkleInsert(_ timestamp: String, db: Database) throws {
        // Local and validated remote timestamps always parse; a stored value that
        // does not could never have been hashed by a peer either.
        guard let parsed = SyncTimestamp.parse(timestamp) else { return }
        var trie = try merkleWorking ?? currentMerkleTrie(db)
        trie.insert(parsed)
        merkleWorking = trie
    }

    private func finishMerkleBatch(_ db: Database) throws {
        guard let working = merkleWorking else { return }
        let pruned = working.pruned()
        try Self.persistMerkleTrie(
            pruned, fallbackTimestamp: localClock?.lastTimestamp, nodeID: localClock?.nodeID, db: db
        )
        merkleStaged = pruned
        merkleWorking = nil
    }

    /// The committed trie: the cache, else the stored clock, else a rebuild from
    /// the message log (a file whose clock row is missing or unreadable).
    func currentMerkleTrie(_ db: Database) throws -> MerkleTrie {
        if let merkleCache { return merkleCache }
        if let stored = try Self.storedMerkleTrie(db) { return stored }
        return try Self.rebuiltMerkleTrie(db)
    }

    /// Milliseconds of the earliest minute where the server's trie and this
    /// file's disagree, or nil when they match.
    func merkleDivergence(from server: MerkleTrie) throws -> Int64? {
        let local = try queue.read { db -> (MerkleTrie, Bool) in
            if let merkleCache { return (merkleCache, false) }
            if let stored = try Self.storedMerkleTrie(db) { return (stored, true) }
            return (try Self.rebuiltMerkleTrie(db), false)
        }
        if local.1 { merkleCache = local.0 }
        return MerkleTrie.diff(server, local.0)
    }

    /// Recomputes the trie from `messages_crdt`, persists it and replaces the
    /// cache. Upstream's out-of-sync guard does the same before giving up.
    func rebuildMerkleTrie() throws {
        let rebuilt = try queue.write { db in
            let trie = try Self.rebuiltMerkleTrie(db)
            try Self.persistMerkleTrie(
                trie, fallbackTimestamp: localClock?.lastTimestamp, nodeID: localClock?.nodeID, db: db
            )
            return trie
        }
        merkleCache = rebuilt
    }

    var localClockTimestamp: String? { localClock?.lastTimestamp }

    // MARK: Open-time rebuild

    /// An imported `messages_clock` is not trusted: it may come from a build that
    /// never kept the trie or from a different codebase. Rebuild once per file.
    static func prepareMerkleTrie(in queue: DatabaseQueue, localNodeID: String?) throws {
        try queue.write { db in
            guard try tableExists("messages_crdt", in: db),
                  try !localMigrationApplied(merkleRebuildMigration, in: db) else {
                return
            }
            let trie = try rebuiltMerkleTrie(db)
            let hadClockRow = try hasClockRow(db)
            if !trie.isEmpty || hadClockRow {
                try persistMerkleTrie(trie, fallbackTimestamp: nil, nodeID: localNodeID, db: db)
            }
            try recordLocalMigration(merkleRebuildMigration, in: db)
        }
    }

    // MARK: Table access

    static func rebuiltMerkleTrie(_ db: Database) throws -> MerkleTrie {
        guard try tableExists("messages_crdt", in: db) else { return .empty }
        var trie = MerkleTrie()
        let cursor = try String.fetchCursor(db, sql: "SELECT timestamp FROM messages_crdt")
        while let timestamp = try cursor.next() {
            if let parsed = SyncTimestamp.parse(timestamp) {
                trie.insert(parsed)
            }
        }
        return trie.pruned()
    }

    private static func storedClockJSON(_ db: Database) throws -> [String: Any]? {
        guard try tableExists("messages_clock", in: db),
              let text = try String.fetchOne(db, sql: "SELECT clock FROM messages_clock ORDER BY id LIMIT 1"),
              let data = text.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func storedMerkleTrie(_ db: Database) throws -> MerkleTrie? {
        guard let json = try storedClockJSON(db), let merkle = json["merkle"] else { return nil }
        return MerkleTrie(jsonObject: merkle)
    }

    private static func hasClockRow(_ db: Database) throws -> Bool {
        guard try tableExists("messages_clock", in: db) else { return false }
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_clock") ?? 0
        return count > 0
    }

    /// Writes upstream's `{"timestamp": <HLC>, "merkle": {...}}`, keeping the
    /// stored HLC when it is valid (it names the node other clients adopt).
    static func persistMerkleTrie(
        _ trie: MerkleTrie,
        fallbackTimestamp: String?,
        nodeID: String?,
        db: Database
    ) throws {
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS messages_clock (id INTEGER PRIMARY KEY, clock TEXT)")
        let stored = try storedClockJSON(db)?["timestamp"] as? String
        let timestamp: String
        if let stored, SyncTimestamp.parse(stored) != nil {
            timestamp = stored
        } else if let fallbackTimestamp, SyncTimestamp.parse(fallbackTimestamp) != nil {
            timestamp = fallbackTimestamp
        } else {
            let node = HybridLogicalClock.normalizedNodeID(nodeID ?? "")
            let padding = String(repeating: "0", count: max(0, 16 - node.count))
            timestamp = String(SyncTimestamp.zeroString.dropLast(16)) + padding + node
        }
        let clock = "{\"timestamp\":\"\(timestamp)\",\"merkle\":\(trie.jsonString)}"
        try db.execute(sql: "DELETE FROM messages_clock WHERE id <> 1")
        try db.execute(
            sql: "INSERT OR REPLACE INTO messages_clock (id, clock) VALUES (1, ?)",
            arguments: [clock]
        )
    }

    private static func tableExists(_ name: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            arguments: [name]
        ) ?? false
    }
}

extension BudgetDatabase.RemoteSyncApplyResult {
    /// Totals of a re-pull loop's rounds.
    func merging(_ later: Self) -> Self {
        var ids = insertedTransactionIDsByAccount.mapValues(Set.init)
        for (account, transactionIDs) in later.insertedTransactionIDsByAccount {
            ids[account, default: []].formUnion(transactionIDs)
        }
        return Self(
            appliedMessageCount: appliedMessageCount + later.appliedMessageCount,
            insertedTransactionIDsByAccount: ids.mapValues { $0.sorted() },
            quarantinedTimestamps: quarantinedTimestamps + later.quarantinedTimestamps
        )
    }
}
