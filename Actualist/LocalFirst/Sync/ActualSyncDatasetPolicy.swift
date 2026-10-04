import Foundation

/// Which sync datasets may write local tables.
///
/// Upstream `applyMessages` (`packages/loot-core/src/server/sync/index.ts`)
/// applies every dataset except `prefs` to the budget database and has no
/// denylist, because only trusted peers of the same budget write messages. This
/// client also keeps its own tables (identity, action log, outbox, checkpoint)
/// in the budget file, and several upstream bookkeeping tables have no `id`
/// column, so a hostile or buggy message naming them would corrupt local state
/// or fail every later sync. Such datasets are stored in `messages_crdt` for
/// timestamp and merkle bookkeeping but never applied.
enum ActualSyncDatasetPolicy {
    private static let reservedPrefixes = [
        "sqlite_", "actualist_", "messages_", "kvcache", "__", "db_version"
    ]

    /// SQLite table names are case-insensitive, so match case-insensitively.
    static func isReserved(_ dataset: String) -> Bool {
        let name = dataset.lowercased()
        return reservedPrefixes.contains { name.hasPrefix($0) }
    }
}
