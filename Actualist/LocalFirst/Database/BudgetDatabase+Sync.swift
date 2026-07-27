import Foundation
import GRDB

extension BudgetDatabase {
    struct LocalSyncCheckpoint: Equatable, Sendable {
        let lastSyncedAt: Date
        let lastAppliedMessageCount: Int
        let lastUploadedMessageCount: Int
    }

    func latestSyncTimestamp() throws -> String {
        try queue.read { db in
            guard try tableExists("messages_crdt", db: db) else {
                return "1970-01-01T00:00:00.000Z-0000-0000000000000000"
            }
            let row = try Row.fetchOne(db, sql: "SELECT MAX(timestamp) AS timestamp FROM messages_crdt")
            return row?["timestamp"] as String? ?? "1970-01-01T00:00:00.000Z-0000-0000000000000000"
        }
    }

    func applyRemoteSyncMessages(_ messages: [ActualSyncDecodedMessage]) throws -> Int {
        try applyRemoteSyncMessagesTrackingInserts(messages).appliedMessageCount
    }

    func applyRemoteSyncMessagesTrackingInserts(
        _ messages: [ActualSyncDecodedMessage]
    ) throws -> RemoteSyncApplyResult {
        guard !messages.isEmpty else {
            return .empty
        }

        let result = try queue.write { db in
            guard try tableExists("messages_crdt", db: db) else {
                return RemoteSyncApplyResult.empty
            }

            var appliedCount = 0
            let sortedMessages = messages.sorted { $0.timestamp < $1.timestamp }
            var insertedRows = Set<String>()
            var insertedTransactionIDs = Set<String>()

            for message in sortedMessages {
                if try hasSameOrNewerMessage(message, db: db) {
                    continue
                }

                guard try tableExists(message.dataset, db: db) else {
                    try insertCRDTMessage(message, db: db)
                    appliedCount += 1
                    continue
                }
                guard try columnSet(for: message.dataset, db: db).contains(message.column) else {
                    try insertCRDTMessage(message, db: db)
                    appliedCount += 1
                    continue
                }

                let rowWasInserted = insertedRows.contains(message.dataset + message.row)
                let hasRow: Bool
                if rowWasInserted {
                    hasRow = true
                } else {
                    hasRow = try rowExists(table: message.dataset, rowID: message.row, db: db)
                }
                let value = try deserializeSyncValue(message.serializedValue)
                if message.dataset != "prefs" {
                    try apply(message: message, value: value, rowExists: hasRow, db: db)
                    insertedRows.insert(message.dataset + message.row)
                    if message.dataset == "transactions", !hasRow {
                        insertedTransactionIDs.insert(message.row)
                    }
                }
                try insertCRDTMessage(message, db: db)
                appliedCount += 1
            }

            return RemoteSyncApplyResult(
                appliedMessageCount: appliedCount,
                insertedTransactionIDsByAccount: try liveTopLevelTransactionIDsByAccount(
                    candidateIDs: insertedTransactionIDs,
                    db: db
                )
            )
        }
        if var clock = localClock {
            for message in messages {
                clock.observe(message.timestamp)
            }
            localClock = clock
        }
        return result
    }

    private func liveTopLevelTransactionIDsByAccount(
        candidateIDs: Set<String>,
        db: Database
    ) throws -> [String: [String]] {
        guard !candidateIDs.isEmpty,
              try tableExists("transactions", db: db) else {
            return [:]
        }

        let columns = try columnSet(for: "transactions", db: db)
        let account = column(
            "acct",
            fallback: column("account", fallback: "NULL", columns: columns),
            columns: columns
        )
        var topLevelPredicates = [predicateForLiveRows(columns: columns)]
        if columns.contains("parent_id") {
            topLevelPredicates.append("parent_id IS NULL")
        }
        if columns.contains("isChild") {
            topLevelPredicates.append("(isChild IS NULL OR isChild = 0)")
        } else if columns.contains("is_child") {
            topLevelPredicates.append("(is_child IS NULL OR is_child = 0)")
        }

        var result: [String: [String]] = [:]
        let sortedCandidateIDs = candidateIDs.sorted()
        for start in stride(from: 0, to: sortedCandidateIDs.count, by: 400) {
            let end = min(start + 400, sortedCandidateIDs.count)
            let batch = Array(sortedCandidateIDs[start..<end])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, \(account) AS account_id
                    FROM transactions
                    WHERE id IN (\(placeholders))
                      AND \(topLevelPredicates.joined(separator: " AND "))
                    """,
                arguments: StatementArguments(batch)
            )
            for row in rows {
                guard let id = row["id"] as String?,
                      let accountID = row["account_id"] as String?,
                      !id.isEmpty,
                      !accountID.isEmpty else {
                    continue
                }
                result[accountID, default: []].append(id)
            }
        }
        return result.mapValues { $0.sorted() }
    }

    func applyLocalSyncMessages(_ messages: [ActualSyncDecodedMessage]) throws -> Int {
        try applyLocalSyncMessages(messages, outboxBaseTimestamp: nil)
    }

    func applyLocalSyncMessagesAndEnqueue(
        _ messages: [ActualSyncDecodedMessage],
        baseTimestamp: String
    ) throws -> Int {
        try applyLocalSyncMessages(messages, outboxBaseTimestamp: baseTimestamp)
    }

    /// Finalizes mutation drafts under the database actor. The clock is copied only so a failed
    /// transaction does not advance in-memory state; the successful value is written back before
    /// this actor method returns. There is no suspension point between timestamp minting, CRDT
    /// application, and durable outbox insertion.
    func commitLocalSyncMessagesAndEnqueue(
        _ drafts: [ActualSyncDecodedMessage],
        now: Date = Date()
    ) throws -> Int {
        guard !drafts.isEmpty else {
            return 0
        }
        guard var clock = localClock else {
            throw LocalFirstError.invalidLocalWrite("local clock is not configured")
        }

        let appliedCount: Int
        do {
            appliedCount = try queue.write { db in
                guard try tableExists("messages_crdt", db: db) else {
                    throw LocalFirstError.invalidLocalWrite("missing messages_crdt table")
                }
                try ensureLocalSyncOutbox(db)
                let baseTimestamp = try String.fetchOne(
                    db,
                    sql: "SELECT MAX(timestamp) FROM messages_crdt"
                ) ?? "1970-01-01T00:00:00.000Z-0000-0000000000000000"

                var appliedCount = 0
                var insertedRows = Set<String>()
                for draft in drafts.sorted(by: { $0.timestamp < $1.timestamp }) {
                    let message = ActualSyncDecodedMessage(
                        timestamp: try clock.next(now: now),
                        dataset: draft.dataset,
                        row: draft.row,
                        column: draft.column,
                        serializedValue: draft.serializedValue
                    )
                    try validateLocalMessage(message, db: db)

                    if try hasSameOrNewerMessage(message, db: db) {
                        throw LocalFirstError.localWriteSuperseded
                    }

                    let rowKey = message.dataset + message.row
                    let hasRow: Bool
                    if insertedRows.contains(rowKey) {
                        hasRow = true
                    } else {
                        hasRow = try rowExists(
                            table: message.dataset,
                            rowID: message.row,
                            db: db
                        )
                    }
                    let value = try deserializeSyncValue(message.serializedValue)
                    try apply(message: message, value: value, rowExists: hasRow, db: db)
                    insertedRows.insert(rowKey)
                    try insertCRDTMessage(message, db: db)
                    try insertLocalSyncOutboxMessage(
                        message,
                        baseTimestamp: baseTimestamp,
                        db: db
                    )
                    appliedCount += 1
                }
                return appliedCount
            }
        } catch let error as LocalFirstError {
            throw error
        } catch {
            throw LocalFirstError.invalidLocalWrite("the database transaction was rolled back")
        }
        localClock = clock
        return appliedCount
    }

    func applyLocalSyncMessages(
        _ messages: [ActualSyncDecodedMessage],
        outboxBaseTimestamp: String?
    ) throws -> Int {
        guard !messages.isEmpty else {
            return 0
        }

        return try queue.write { db in
            guard try tableExists("messages_crdt", db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing messages_crdt table")
            }
            if outboxBaseTimestamp != nil {
                try ensureLocalSyncOutbox(db)
            }

            var appliedCount = 0
            let sortedMessages = messages.sorted { $0.timestamp < $1.timestamp }
            var insertedRows = Set<String>()

            for message in sortedMessages {
                try validateLocalMessage(message, db: db)

                if try hasSameOrNewerMessage(message, db: db) {
                    throw LocalFirstError.localWriteSuperseded
                }

                let rowWasInserted = insertedRows.contains(message.dataset + message.row)
                let hasRow: Bool
                if rowWasInserted {
                    hasRow = true
                } else {
                    hasRow = try rowExists(table: message.dataset, rowID: message.row, db: db)
                }

                let value = try deserializeSyncValue(message.serializedValue)
                try apply(message: message, value: value, rowExists: hasRow, db: db)
                insertedRows.insert(message.dataset + message.row)
                try insertCRDTMessage(message, db: db)
                if let outboxBaseTimestamp {
                    try insertLocalSyncOutboxMessage(message, baseTimestamp: outboxBaseTimestamp, db: db)
                }
                appliedCount += 1
            }

            return appliedCount
        }
    }

    func pendingLocalSyncMessageCount() throws -> Int {
        try queue.read { db in
            guard try tableExists("actualist_outbox", db: db) else {
                return 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actualist_outbox") ?? 0
        }
    }

    func localSyncCheckpoint() throws -> LocalSyncCheckpoint? {
        try queue.read { db in
            guard try tableExists("actualist_sync_checkpoint", db: db),
                  let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT last_synced_at, last_applied_message_count, last_uploaded_message_count
                        FROM actualist_sync_checkpoint
                        WHERE id = 1
                        """
                  ),
                  let lastSyncedAt = row["last_synced_at"] as Double?,
                  let lastAppliedMessageCount = row["last_applied_message_count"] as Int?,
                  let lastUploadedMessageCount = row["last_uploaded_message_count"] as Int? else {
                return nil
            }
            return LocalSyncCheckpoint(
                lastSyncedAt: Date(timeIntervalSince1970: lastSyncedAt),
                lastAppliedMessageCount: lastAppliedMessageCount,
                lastUploadedMessageCount: lastUploadedMessageCount
            )
        }
    }

    func saveLocalSyncCheckpoint(_ checkpoint: LocalSyncCheckpoint) throws {
        try queue.write { db in
            try ensureLocalSyncCheckpoint(db)
            try db.execute(
                sql: """
                    INSERT INTO actualist_sync_checkpoint
                        (id, last_synced_at, last_applied_message_count, last_uploaded_message_count)
                    VALUES (1, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        last_synced_at = excluded.last_synced_at,
                        last_applied_message_count = excluded.last_applied_message_count,
                        last_uploaded_message_count = excluded.last_uploaded_message_count
                    """,
                arguments: [
                    checkpoint.lastSyncedAt.timeIntervalSince1970,
                    checkpoint.lastAppliedMessageCount,
                    checkpoint.lastUploadedMessageCount
                ]
            )
        }
    }

    func pendingLocalSyncMessages(limit: Int = 500) throws -> [PendingLocalSyncMessage] {
        try queue.read { db in
            guard try tableExists("actualist_outbox", db: db) else {
                return []
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT timestamp, dataset, row, column, value, base_timestamp,
                           attempt_count, last_error
                    FROM actualist_outbox
                    ORDER BY timestamp ASC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
            return rows.map { row in
                PendingLocalSyncMessage(
                    message: ActualSyncDecodedMessage(
                        timestamp: row["timestamp"] ?? "",
                        dataset: row["dataset"] ?? "",
                        row: row["row"] ?? "",
                        column: row["column"] ?? "",
                        serializedValue: row["value"] ?? ""
                    ),
                    baseTimestamp: row["base_timestamp"] ?? "1970-01-01T00:00:00.000Z-0000-0000000000000000",
                    attemptCount: row["attempt_count"] ?? 0,
                    lastError: row["last_error"]
                )
            }
        }
    }

    func deletePendingLocalSyncMessages(_ messages: [PendingLocalSyncMessage]) throws {
        guard !messages.isEmpty else {
            return
        }
        try queue.write { db in
            guard try tableExists("actualist_outbox", db: db) else {
                return
            }
            for pending in messages {
                try db.execute(
                    sql: "DELETE FROM actualist_outbox WHERE timestamp = ?",
                    arguments: [pending.message.timestamp]
                )
            }
        }
    }

    func markPendingLocalSyncMessagesFailed(_ messages: [PendingLocalSyncMessage], error: Error) throws {
        guard !messages.isEmpty else {
            return
        }
        let message = error.localizedDescription
        try queue.write { db in
            guard try tableExists("actualist_outbox", db: db) else {
                return
            }
            for pending in messages {
                try db.execute(
                    sql: """
                        UPDATE actualist_outbox
                        SET attempt_count = attempt_count + 1,
                            last_attempt_at = ?,
                            last_error = ?
                        WHERE timestamp = ?
                        """,
                    arguments: [Self.outboxDateString(Date()), message, pending.message.timestamp]
                )
            }
        }
    }

    func hasSameOrNewerMessage(_ message: ActualSyncDecodedMessage, db: Database) throws -> Bool {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT timestamp FROM messages_crdt
                WHERE dataset = ? AND row = ? AND column = ? AND timestamp >= ?
                ORDER BY timestamp ASC
                LIMIT 1
                """,
            arguments: [message.dataset, message.row, message.column, message.timestamp]
        )
        return row != nil
    }

    func validateLocalMessage(_ message: ActualSyncDecodedMessage, db: Database) throws {
        guard try tableExists(message.dataset, db: db) else {
            throw LocalFirstError.invalidLocalWrite("unknown dataset \(message.dataset)")
        }
        let columns = try columnSet(for: message.dataset, db: db)
        guard columns.contains(message.column) else {
            throw LocalFirstError.invalidLocalWrite("unknown column \(message.dataset).\(message.column)")
        }
    }

    func apply(
        message: ActualSyncDecodedMessage,
        value: ActualSyncSQLiteValue,
        rowExists: Bool,
        db: Database
    ) throws {
        if message.dataset == "zero_budgets",
           try !columnSet(for: "zero_budgets", db: db).contains("id") {
            try applyZeroBudgetMessageWithoutID(message: message, value: value, rowExists: rowExists, db: db)
            return
        }

        let table = quotedIdentifier(message.dataset)
        let column = quotedIdentifier(message.column)
        if rowExists {
            switch value {
            case .null:
                try db.execute(
                    sql: "UPDATE \(table) SET \(column) = NULL WHERE id = ?",
                    arguments: [message.row]
                )
            case .int(let value):
                try db.execute(
                    sql: "UPDATE \(table) SET \(column) = ? WHERE id = ?",
                    arguments: [value, message.row]
                )
            case .double(let value):
                try db.execute(
                    sql: "UPDATE \(table) SET \(column) = ? WHERE id = ?",
                    arguments: [value, message.row]
                )
            case .string(let value):
                try db.execute(
                    sql: "UPDATE \(table) SET \(column) = ? WHERE id = ?",
                    arguments: [value, message.row]
                )
            }
        } else {
            switch value {
            case .null:
                try db.execute(
                    sql: "INSERT INTO \(table) (id, \(column)) VALUES (?, NULL)",
                    arguments: [message.row]
                )
            case .int(let value):
                try db.execute(
                    sql: "INSERT INTO \(table) (id, \(column)) VALUES (?, ?)",
                    arguments: [message.row, value]
                )
            case .double(let value):
                try db.execute(
                    sql: "INSERT INTO \(table) (id, \(column)) VALUES (?, ?)",
                    arguments: [message.row, value]
                )
            case .string(let value):
                try db.execute(
                    sql: "INSERT INTO \(table) (id, \(column)) VALUES (?, ?)",
                    arguments: [message.row, value]
                )
            }
        }
    }

    func applyZeroBudgetMessageWithoutID(
        message: ActualSyncDecodedMessage,
        value: ActualSyncSQLiteValue,
        rowExists: Bool,
        db: Database
    ) throws {
        let columns = try columnSet(for: "zero_budgets", db: db)
        let key = try zeroBudgetKey(from: message.row)
        let column = quotedIdentifier(message.column)
        if rowExists {
            switch value {
            case .null:
                try db.execute(
                    sql: "UPDATE zero_budgets SET \(column) = NULL WHERE \(normalizedMonthExpression("month")) = ? AND category = ?",
                    arguments: [key.monthID, key.categoryID]
                )
            case .int(let value):
                try db.execute(
                    sql: "UPDATE zero_budgets SET \(column) = ? WHERE \(normalizedMonthExpression("month")) = ? AND category = ?",
                    arguments: [value, key.monthID, key.categoryID]
                )
            case .double(let value):
                try db.execute(
                    sql: "UPDATE zero_budgets SET \(column) = ? WHERE \(normalizedMonthExpression("month")) = ? AND category = ?",
                    arguments: [value, key.monthID, key.categoryID]
                )
            case .string(let value):
                try db.execute(
                    sql: "UPDATE zero_budgets SET \(column) = ? WHERE \(normalizedMonthExpression("month")) = ? AND category = ?",
                    arguments: [value, key.monthID, key.categoryID]
                )
            }
            return
        }

        var insertColumns = ["month", "category"]
        var arguments: [DatabaseValueConvertible] = [key.monthValue, key.categoryID]
        if columns.contains("carryover") {
            insertColumns.append("carryover")
            arguments.append(0)
        }
        if message.column != "month", message.column != "category", message.column != "carryover" {
            insertColumns.append(message.column)
            arguments.append(databaseValue(for: value))
        }

        let quotedColumns = insertColumns.map(quotedIdentifier).joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: insertColumns.count).joined(separator: ", ")
        try db.execute(
            sql: "INSERT INTO zero_budgets (\(quotedColumns)) VALUES (\(placeholders))",
            arguments: StatementArguments(arguments)
        )
    }

    func databaseValue(for value: ActualSyncSQLiteValue) -> DatabaseValueConvertible {
        switch value {
        case .null:
            return DatabaseValue.null
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        }
    }

    func insertCRDTMessage(_ message: ActualSyncDecodedMessage, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO messages_crdt (timestamp, dataset, row, column, value)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                message.timestamp,
                message.dataset,
                message.row,
                message.column,
                message.serializedValue
            ]
        )
    }

    func ensureLocalSyncOutbox(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS actualist_outbox (
                timestamp TEXT PRIMARY KEY,
                dataset TEXT NOT NULL,
                row TEXT NOT NULL,
                column TEXT NOT NULL,
                value TEXT NOT NULL,
                base_timestamp TEXT NOT NULL,
                created_at TEXT NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_attempt_at TEXT,
                last_error TEXT
            )
            """)
        // `tableExists` caches both positive and negative lookups. A budget opened before its
        // first local write therefore has a cached `false` for this lazily-created table unless
        // creation invalidates the cache. Do not cache `true` here: this call is inside the local
        // write transaction, and a later validation error could roll the table creation back.
        tableExistsCache["actualist_outbox"] = nil
    }

    func ensureLocalSyncCheckpoint(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS actualist_sync_checkpoint (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                last_synced_at REAL NOT NULL,
                last_applied_message_count INTEGER NOT NULL,
                last_uploaded_message_count INTEGER NOT NULL
            )
            """)
        tableExistsCache["actualist_sync_checkpoint"] = nil
    }

    func insertLocalSyncOutboxMessage(
        _ message: ActualSyncDecodedMessage,
        baseTimestamp: String,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO actualist_outbox
                    (timestamp, dataset, row, column, value, base_timestamp, created_at,
                     attempt_count, last_attempt_at, last_error)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0, NULL, NULL)
                """,
            arguments: [
                message.timestamp,
                message.dataset,
                message.row,
                message.column,
                message.serializedValue,
                baseTimestamp,
                Self.outboxDateString(Date())
            ]
        )
    }

    static func outboxDateString(_ date: Date) -> String {
        outboxDateFormatterLock.lock()
        defer { outboxDateFormatterLock.unlock() }
        return outboxDateFormatter.string(from: date)
    }

    private static let outboxDateFormatterLock = NSLock()
    private static let outboxDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    func deserializeSyncValue(_ value: String) throws -> ActualSyncSQLiteValue {
        guard let type = value.first else {
            throw LocalFirstError.invalidDownloadedBudget
        }
        let payload = String(value.dropFirst(2))
        switch type {
        case "0":
            return .null
        case "N":
            guard let number = Double(payload) else {
                throw LocalFirstError.invalidDownloadedBudget
            }
            guard number.isFinite else {
                throw LocalFirstError.invalidDownloadedBudget
            }
            if number.rounded() == number, let int = Int64(exactly: number) {
                return .int(int)
            }
            return .double(number)
        case "S":
            return .string(payload)
        default:
            throw LocalFirstError.invalidDownloadedBudget
        }
    }
}
