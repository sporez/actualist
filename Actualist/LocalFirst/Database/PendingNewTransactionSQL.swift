import Foundation
import GRDB

enum PendingNewTransactionSource: String, Sendable {
    case remoteSync
    case bankSync
    case legacySettings
}

struct PendingNewTransactionCommit: Sendable {
    let transactionIDsByAccount: [String: [String]]
    let source: PendingNewTransactionSource
    let notificationID: String?
    let notificationAlreadyAcknowledged: Bool

    init(
        transactionIDsByAccount: [String: [String]],
        source: PendingNewTransactionSource,
        notificationID: String?,
        notificationAlreadyAcknowledged: Bool = false
    ) {
        self.transactionIDsByAccount = transactionIDsByAccount
        self.source = source
        self.notificationID = notificationID
        self.notificationAlreadyAcknowledged = notificationAlreadyAcknowledged
    }
}

enum PendingNewTransactionSQL {
    private static let pendingNewTransactionLegacyMigration = "pending-new-transactions-legacy-settings-v1"

    struct PendingNewTransactionDelivery: Equatable, Sendable {
        let notificationID: String
        let transactionIDs: [String]
    }

    static func preparePendingNewTransactionSchema(in queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS actualist_pending_new_transactions (
                    transaction_id TEXT PRIMARY KEY,
                    account_id TEXT NOT NULL,
                    source TEXT NOT NULL,
                    detected_at REAL NOT NULL,
                    notification_id TEXT,
                    notification_acknowledged_at REAL,
                    reviewed_at REAL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS actualist_pending_new_transactions_review
                ON actualist_pending_new_transactions(reviewed_at, account_id)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS actualist_pending_new_transactions_delivery
                ON actualist_pending_new_transactions(notification_acknowledged_at, reviewed_at, detected_at)
                """)
        }
    }

    static func recordPendingNewTransactions(_ commit: PendingNewTransactionCommit, in database: isolated BudgetDatabase) throws {
        guard !commit.transactionIDsByAccount.isEmpty else { return }
        try database.queue.write { db in
            try recordPendingNewTransactions(commit, in: database, db: db)
        }
    }

    static func migrateLegacyPendingNewTransactions(_ transactionIDsByAccount: [String: [String]], in database: isolated BudgetDatabase) throws {
        try database.queue.write { db in
            try migrateLegacyPendingNewTransactions(transactionIDsByAccount, in: database, db: db)
        }
    }

    private static func migrateLegacyPendingNewTransactions(
        _ transactionIDsByAccount: [String: [String]],
        in database: isolated BudgetDatabase,
        db: Database
    ) throws {
        guard !(try BudgetDatabase.localMigrationApplied(
            Self.pendingNewTransactionLegacyMigration,
            in: db
        )) else { return }
        if !transactionIDsByAccount.isEmpty {
            try recordPendingNewTransactions(.init(
                transactionIDsByAccount: transactionIDsByAccount,
                source: .legacySettings,
                notificationID: nil,
                notificationAlreadyAcknowledged: true
            ), in: database, db: db)
        }
        try BudgetDatabase.recordLocalMigration(Self.pendingNewTransactionLegacyMigration, in: db)
    }

    static func recordPendingNewTransactions(
        _ commit: PendingNewTransactionCommit,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws {
        let now = Date().timeIntervalSince1970
        let acknowledgedAt: Double? = commit.notificationAlreadyAcknowledged ? now : nil
        for (accountID, transactionIDs) in commit.transactionIDsByAccount {
            for transactionID in Set(transactionIDs) where !transactionID.isEmpty {
                // A reviewed row is a durable tombstone. Re-observing the same
                // transaction must never make it new again.
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO actualist_pending_new_transactions
                            (transaction_id, account_id, source, detected_at, notification_id,
                             notification_acknowledged_at, reviewed_at)
                        VALUES (?, ?, ?, ?, ?, ?, NULL)
                        """,
                    arguments: [
                        transactionID,
                        accountID,
                        commit.source.rawValue,
                        now,
                        commit.notificationID,
                        acknowledgedAt
                    ]
                )
            }
        }
    }

    static func pendingNewTransactionIDsByAccount(in database: isolated BudgetDatabase) throws -> [String: [String]] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT transaction_id, account_id
                FROM actualist_pending_new_transactions
                WHERE reviewed_at IS NULL
                ORDER BY account_id, transaction_id
                """)
            return rows.reduce(into: [String: [String]]()) { result, row in
                guard let transactionID: String = row["transaction_id"],
                      let accountID: String = row["account_id"] else { return }
                result[accountID, default: []].append(transactionID)
            }
        }
    }

    static func pendingNewTransactionDelivery(in database: isolated BudgetDatabase) throws -> PendingNewTransactionDelivery? {
        try database.queue.read { db in
            guard let notificationID = try String.fetchOne(db, sql: """
                SELECT notification_id
                FROM actualist_pending_new_transactions
                WHERE reviewed_at IS NULL
                  AND notification_acknowledged_at IS NULL
                  AND notification_id IS NOT NULL
                ORDER BY detected_at, notification_id
                LIMIT 1
                """) else { return nil }
            let transactionIDs = try String.fetchAll(db, sql: """
                SELECT transaction_id
                FROM actualist_pending_new_transactions
                WHERE reviewed_at IS NULL
                  AND notification_acknowledged_at IS NULL
                  AND notification_id IS NOT NULL
                ORDER BY transaction_id
                """)
            return PendingNewTransactionDelivery(
                notificationID: notificationID,
                transactionIDs: transactionIDs
            )
        }
    }

    static func acknowledgePendingNewTransactionDelivery(_ transactionIDs: [String], in database: isolated BudgetDatabase) throws {
        guard !transactionIDs.isEmpty else { return }
        try updatePendingNewTransactions(
            transactionIDs: transactionIDs,
            assignment: "notification_acknowledged_at = COALESCE(notification_acknowledged_at, ?)",
            value: Date().timeIntervalSince1970,
            in: database
        )
    }

    static func suppressPendingNewTransactionDeliveries(in database: isolated BudgetDatabase) throws {
        try database.queue.write { db in
            try db.execute(
                sql: """
                    UPDATE actualist_pending_new_transactions
                    SET notification_acknowledged_at = COALESCE(notification_acknowledged_at, ?)
                    WHERE notification_acknowledged_at IS NULL
                    """,
                arguments: [Date().timeIntervalSince1970]
            )
        }
    }

    static func migrateLegacyAndReviewPendingNewTransactions(
        _ legacyTransactionIDsByAccount: [String: [String]],
        transactionIDs: Set<String>,
        accountID: String?,
        in database: isolated BudgetDatabase
    ) throws -> Int {
        try database.queue.write { db in
            try migrateLegacyPendingNewTransactions(legacyTransactionIDsByAccount, in: database, db: db)
            let reviewedAt = Date().timeIntervalSince1970
            var reviewedCount = 0
            for transactionID in transactionIDs where !transactionID.isEmpty {
                if let accountID {
                    try db.execute(
                        sql: """
                            UPDATE actualist_pending_new_transactions
                            SET reviewed_at = COALESCE(reviewed_at, ?)
                            WHERE reviewed_at IS NULL AND transaction_id = ? AND account_id = ?
                            """,
                        arguments: [reviewedAt, transactionID, accountID]
                    )
                } else {
                    try db.execute(
                        sql: """
                            UPDATE actualist_pending_new_transactions
                            SET reviewed_at = COALESCE(reviewed_at, ?)
                            WHERE reviewed_at IS NULL AND transaction_id = ?
                            """,
                        arguments: [reviewedAt, transactionID]
                    )
                }
                reviewedCount += db.changesCount
            }
            return reviewedCount
        }
    }

    private static func updatePendingNewTransactions(
        transactionIDs: [String],
        assignment: String,
        value: Double,
        in database: isolated BudgetDatabase
    ) throws {
        try database.queue.write { db in
            for transactionID in transactionIDs {
                try db.execute(
                    sql: """
                        UPDATE actualist_pending_new_transactions
                        SET \(assignment)
                        WHERE transaction_id = ?
                        """,
                    arguments: [value, transactionID]
                )
            }
        }
    }
}
