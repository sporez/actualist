import Foundation
import GRDB

/// The id of one row in Actual's synced `preferences` table.
struct SyncedPreferenceKey: Hashable, Sendable {
    let id: String

    init(_ id: String) {
        self.id = id
    }

    static let learnCategories = SyncedPreferenceKey("learn-categories")
    static let budgetType = SyncedPreferenceKey("budgetType")
    static let upcomingScheduledTransactionLength = SyncedPreferenceKey("upcomingScheduledTransactionLength")
    static let defaultCurrencyCode = SyncedPreferenceKey("defaultCurrencyCode")
    static let hideFraction = SyncedPreferenceKey("hideFraction")
    static let numberFormat = SyncedPreferenceKey("numberFormat")

    static let transactionTableColumns = SyncedPreferenceKey("transaction-table-columns")

    static func showBalances(accountID: String) -> SyncedPreferenceKey {
        SyncedPreferenceKey("show-balances-\(accountID)")
    }

    static func transactionTableColumns(accountID: String) -> SyncedPreferenceKey {
        SyncedPreferenceKey("transaction-table-columns-\(accountID)")
    }
}

/// Every read and write of Actual's synced `preferences` table. Stateless: the
/// actor stays the single owner of the queue, clock, merkle state and write
/// fence, and lends its schema helpers through the `isolated` parameter.
enum SyncedPreferences {
    enum Availability: Equatable, Sendable {
        /// No table, or no `id`/`value` column.
        case unavailable
        /// Actual's own schema has no tombstone column.
        case available(hasTombstone: Bool)
    }

    struct SetResult: Sendable {
        /// Empty when the live value already equals the requested one.
        let messages: [ActualSyncDecodedMessage]
        /// The live value before the write; nil when there was no live row or
        /// its value was NULL.
        let previousValue: String?
    }

    static func availability(
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> Availability {
        try availabilityAndColumns(in: database, db: db).availability
    }

    /// The live value, or nil when absent or the table is unavailable.
    static func value(
        _ key: SyncedPreferenceKey,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> String? {
        guard let columns = try availabilityAndColumns(in: database, db: db).columns else {
            return nil
        }
        return try liveRow(key, columns: columns, in: database, db: db)?.value
    }

    /// The live values among `keys`; absent keys are omitted.
    static func values(
        _ keys: [SyncedPreferenceKey],
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for key in keys {
            result[key.id] = try value(key, in: database, db: db)
        }
        return result
    }

    /// The messages that set `key` to `value`. Throws when the table or its
    /// `value` column is unavailable.
    static func setMessages(
        _ key: SyncedPreferenceKey,
        to value: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> SetResult {
        let columns = try database.requiredColumns(table: "preferences", required: ["id", "value"], db: db)
        let row = try liveRow(key, columns: columns, in: database, db: db)
        guard row?.value != value else {
            return SetResult(messages: [], previousValue: row?.value)
        }
        var messages = [try valueMessage(key, value, builder: &builder)]
        if row == nil, columns.contains("tombstone") {
            messages.append(try builder.revive(dataset: "preferences", row: key.id))
        }
        return SetResult(messages: messages, previousValue: row?.value)
    }

    private struct LiveRow {
        let value: String?
    }

    /// The bare value message, for undo.
    static func valueMessage(
        _ key: SyncedPreferenceKey,
        _ value: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> ActualSyncDecodedMessage {
        try builder.makeMessage(dataset: "preferences", row: key.id, column: "value", value: .string(value))
    }

    private static func availabilityAndColumns(
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> (availability: Availability, columns: Set<String>?) {
        guard try database.tableExists("preferences", db: db) else {
            return (.unavailable, nil)
        }
        let columns = try database.columnSet(for: "preferences", db: db)
        guard columns.contains("id"), columns.contains("value") else {
            return (.unavailable, nil)
        }
        return (.available(hasTombstone: columns.contains("tombstone")), columns)
    }

    /// nil is no live row; a live row with a NULL value is `LiveRow(value: nil)`.
    private static func liveRow(
        _ key: SyncedPreferenceKey,
        columns: Set<String>,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> LiveRow? {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT value FROM preferences
                WHERE id = ? AND \(database.predicateForLiveRows(columns: columns))
                LIMIT 1
                """,
            arguments: [key.id]
        )
        return row.map { LiveRow(value: $0["value"]) }
    }
}

extension BudgetDatabase {
    /// Sets synced preferences in the same transaction that applies and
    /// enqueues their messages: `plan` receives the live values of `reading`
    /// and returns the writes. Records no History entry. Returns whether a
    /// message was written; unchanged values write nothing.
    func commitSyncedPreferences(
        reading keys: [SyncedPreferenceKey],
        plan: @escaping @Sendable ([String: String]) -> [(key: SyncedPreferenceKey, value: String)]
    ) throws -> Bool {
        try commitLocalPlan { db in
            var builder = LocalFirstSyncMessageBuilder()
            var drafts: [ActualSyncDecodedMessage] = []
            let current = try SyncedPreferences.values(keys, in: self, db: db)
            for write in plan(current) {
                drafts += try SyncedPreferences.setMessages(
                    write.key, to: write.value, builder: &builder, in: self, db: db
                ).messages
            }
            return LocalCommitPlan(drafts: drafts, action: nil, outcome: ())
        }.appliedCount > 0
    }
}
