import Foundation
import GRDB

enum BankSyncLinkSQL {
    /// Called inside the same transaction as the import, status and outbox.
    static func validateBankSyncLink(_ expected: BankSyncLinkIdentity?, in database: isolated BudgetDatabase, db: Database) throws {
        guard let expected else { return }
        let storageID = try String.fetchOne(db,
            sql: "SELECT storage_id FROM actualist_budget_identity WHERE id = 1")
        let columns = try database.columnSet(for: "accounts", db: db)
        let closed = database.column("closed", fallback: "0", columns: columns)
        let matches = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM accounts
            WHERE id = ? AND account_id = ? AND account_sync_source = ?
              AND \(database.predicateForLiveRows(columns: columns)) AND COALESCE(\(closed), 0) = 0)
            """, arguments: [expected.accountID, expected.remoteAccountID, expected.syncSource]) ?? false
        guard storageID == expected.storageID, matches else {
            throw LocalFirstError.refusedChange("The bank connection changed. Sync again.")
        }
    }

    /// Open-time backfill for SimpleFIN bank sync. Imported budgets may lack
    /// the `banks` table and the account link columns that Actual's
    /// `linkSimpleFinAccount` writes. Creating them here keeps local CRDT
    /// writes (`validateLocalMessage`) from rejecting link/unlink messages on
    /// older imports. Mirrors the existing `bank_sync_status` backfill.
    static func prepareBankSyncSchemaCompatibility(in queue: DatabaseQueue) throws {
        try queue.write { db in
            let accountsTableExists = try SQLiteSchema.tableExists("accounts", in: db)

            if accountsTableExists {
                let accountColumns = try SQLiteSchema.columns(of: "accounts", in: db)
                let linkColumns: [(column: String, ddl: String)] = [
                    ("account_id", "TEXT"),
                    ("account_sync_source", "TEXT"),
                    ("bank", "TEXT"),
                    ("balance_current", "INTEGER"),
                    ("balance_available", "INTEGER"),
                    ("balance_limit", "INTEGER"),
                    ("last_sync", "TEXT"),
                ]
                for linkColumn in linkColumns
                where !accountColumns.contains(linkColumn.column) {
                    try db.execute(
                        sql: "ALTER TABLE accounts ADD COLUMN \(linkColumn.column) \(linkColumn.ddl)"
                    )
                }
            }

            let banksTableExists = try SQLiteSchema.tableExists("banks", in: db)
            if !banksTableExists {
                // loot-core parity: banks (id, bank_id, name).
                try db.execute(
                    sql: "CREATE TABLE banks (id TEXT PRIMARY KEY, bank_id TEXT, name TEXT)"
                )
            }
        }
    }

    struct BankSyncBankRow: Equatable, Sendable {
        let id: String
        let bankID: String
        let name: String?
    }

    /// The `banks` row a link points at, and the messages that create it.
    struct BankSyncBankResolution: Sendable {
        let bank: BankSyncBankRow
        /// Empty when the row already exists on the server.
        let messages: [ActualSyncDecodedMessage]
    }

    /// loot-core `findOrCreateBank`: match on **both** `bank_id` and `name`.
    /// The same `(bank_id, name)` pair reuses the row; the same `bank_id` with
    /// a different name creates a distinct bank row. A new row is created by
    /// messages, as `db.insertWithUUID` does, so it syncs in the same commit as
    /// the link. Builds before this wrote the row without a message; a matching
    /// row with no stored message gets the same messages, so it reaches the
    /// server on the next link.
    static func findOrCreateBank(
        bankID: String,
        name: String?,
        makeID: @Sendable () -> String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> BankSyncBankResolution {
        let found: (bank: BankSyncBankRow, isSynced: Bool)? = try database.queue.read { db in
            let columns = try database.columnSet(for: "banks", db: db)
            guard columns.contains("bank_id") else {
                throw LocalFirstError.invalidLocalWrite("missing column banks.bank_id")
            }

            let existingRow: Row?
            if let name {
                existingRow = try Row.fetchOne(
                    db,
                    sql: "SELECT id, bank_id, name FROM banks WHERE bank_id = ? AND name IS ? LIMIT 1",
                    arguments: [bankID, name]
                )
            } else {
                existingRow = try Row.fetchOne(
                    db,
                    sql: "SELECT id, bank_id, name FROM banks WHERE bank_id = ? AND name IS NULL LIMIT 1",
                    arguments: [bankID]
                )
            }

            guard let existingRow,
                  let id: String = existingRow["id"],
                  let existingBankID: String = existingRow["bank_id"] else {
                return nil
            }
            var isSynced = false
            if try database.tableExists("messages_crdt", db: db) {
                isSynced = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM messages_crdt WHERE dataset = 'banks' AND row = ?)",
                    arguments: [id]
                ) ?? false
            }
            return (BankSyncBankRow(id: id, bankID: existingBankID, name: existingRow["name"]), isSynced)
        }
        if let found, found.isSynced {
            return BankSyncBankResolution(bank: found.bank, messages: [])
        }
        let bank = found?.bank ?? BankSyncBankRow(id: makeID(), bankID: bankID, name: name)
        let messages = [
            try builder.makeMessage(dataset: "banks", row: bank.id, column: "bank_id", value: .string(bank.bankID)),
            try builder.makeMessage(
                dataset: "banks", row: bank.id, column: "name", value: bank.name.map { .string($0) } ?? .null
            )
        ]
        return BankSyncBankResolution(bank: bank, messages: messages)
    }

    // MARK: - Reads (Phase 3)

    struct BankSyncLinkedAccount: Equatable, Sendable {
        let id: String
        let name: String
        let remoteAccountID: String
        let syncSource: String
        let offbudget: Bool
        let lastSync: String?
        let bankSyncStatus: String?
    }

    /// Accounts with a remote bank-sync link. `account_sync_source` is
    /// preserved verbatim so GoCardless (etc.) links are never sync targets.
    static func bankSyncLinkedAccounts(in database: isolated BudgetDatabase) throws -> [BankSyncLinkedAccount] {
        try database.queue.read { db in
            guard try database.tableExists("accounts", db: db) else { return [] }
            let columns = try database.columnSet(for: "accounts", db: db)
            guard columns.contains("account_id"), columns.contains("account_sync_source") else {
                return []
            }
            let offbudget = database.column("offbudget", fallback: "0", columns: columns)
            let lastSync = database.column("last_sync", fallback: "NULL", columns: columns)
            let status = database.column("bank_sync_status", fallback: "NULL", columns: columns)
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, \(offbudget) AS offbudget, account_id,
                           account_sync_source, \(lastSync) AS last_sync,
                           \(status) AS bank_sync_status
                    FROM accounts
                    WHERE \(database.predicateForLiveRows(columns: columns))
                      AND account_id IS NOT NULL AND account_id != ''
                    ORDER BY lower(name)
                    """
            ).compactMap { row in
                guard let id: String = row["id"],
                      let remoteID: String = row["account_id"],
                      let source: String = row["account_sync_source"] else {
                    return nil
                }
                return BankSyncLinkedAccount(
                    id: id,
                    name: row["name"] ?? "",
                    remoteAccountID: remoteID,
                    syncSource: source,
                    offbudget: (row["offbudget"] as Int? ?? 0) != 0,
                    lastSync: row["last_sync"],
                    bankSyncStatus: row["bank_sync_status"]
                )
            }
        }
    }

    /// The `banks.name` each account's link points at, by local account ID;
    /// an account without a bank row or name is absent. loot-core reads the
    /// row by ID without a tombstone check (`db.select('banks', acctRow.bank)`
    /// in `syncAccount`) and sends the name as Enable Banking's `aspspName`.
    static func bankSyncBankNames(
        accountIDs: [String],
        in database: isolated BudgetDatabase
    ) throws -> [String: String] {
        guard !accountIDs.isEmpty else { return [:] }
        return try database.queue.read { db in
            guard try database.tableExists("banks", db: db),
                  try database.columnSet(for: "accounts", db: db).contains("bank"),
                  try database.columnSet(for: "banks", db: db).contains("name") else {
                return [:]
            }
            let placeholders = Array(repeating: "?", count: accountIDs.count).joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT accounts.id AS account, banks.name AS name
                    FROM accounts JOIN banks ON banks.id = accounts.bank
                    WHERE accounts.id IN (\(placeholders)) AND banks.name IS NOT NULL
                    """,
                arguments: StatementArguments(accountIDs)
            )
            return rows.reduce(into: [:]) { names, row in
                guard let account = SQLiteValueCoercion.text(row, "account"),
                      let name = SQLiteValueCoercion.text(row, "name") else { return }
                names[account] = name
            }
        }
    }

    /// Oldest live transaction day for the account (`YYYYMMDD`), for the
    /// sync lookback start. `nil` when the account has no live rows. Rows dated
    /// after `todayDayID` (the local day) are ignored (`getAccountOldestTransaction`, sync.ts).
    static func bankSyncOldestLiveTransactionDayID(
        accountID: String,
        todayDayID: String = BankSyncAmounts.todayDayID(),
        in database: isolated BudgetDatabase
    ) throws -> String? {
        try database.queue.read { db in
            guard try database.tableExists("transactions", db: db) else { return nil }
            let columns = try database.columnSet(for: "transactions", db: db)
            let split = TransactionSplitQueryExpressions(columns: columns)
            let oldest: Int? = try Int.fetchOne(
                db,
                sql: """
                    SELECT MIN(date) FROM transactions
                    WHERE \(split.account) = ? AND \(database.predicateForLiveRows(columns: columns)) AND date <= ?
                    """,
                arguments: [accountID, Int(todayDayID)]
            )
            return oldest.map(String.init)
        }
    }

    /// Actual `normalizeBankSyncTransactions` defaults missing pending/notes
    /// preferences to true. Custom mapping JSON is returned raw so the planner
    /// can fail closed on invalid JSON instead of this helper guessing.
    struct BankSyncImportPreferences: Equatable, Sendable {
        var importPending: Bool
        var importNotes: Bool
        var customMappingsJSON: String?
    }

    static func bankSyncImportPreferences(accountID: String, in database: isolated BudgetDatabase) throws -> BankSyncImportPreferences {
        try database.queue.read { db in
            func flag(_ key: String, in database: isolated BudgetDatabase) throws -> Bool {
                (try SyncedPreferences.value(SyncedPreferenceKey(key), in: database, db: db) ?? "true") == "true"
            }
            return BankSyncImportPreferences(
                importPending: try flag("sync-import-pending-\(accountID)", in: database),
                importNotes: try flag("sync-import-notes-\(accountID)", in: database),
                customMappingsJSON: try SyncedPreferences.value(
                    SyncedPreferenceKey("custom-sync-mappings-\(accountID)"),
                    in: database,
                    db: db
                )
            )
        }
    }

    /// `sync-update-dates-<account>`; upstream defaults a missing preference to off.
    static func bankSyncUpdatesDates(accountID: String, in database: isolated BudgetDatabase) throws -> Bool {
        try database.queue.read { db in try SyncedPreferences.value(SyncedPreferenceKey("sync-update-dates-\(accountID)"), in: database, db: db) == "true" }
    }

    /// Actual 26.9.0 matchTransactions defaults a missing preference to true.
    /// Deleted IDs are account-wide dedupe keys, never mutable match rows.
    /// `ignoringPreference` is the explicit `reimportDeleted: false` option.
    static func bankSyncSuppressedFinancialIDs(accountID: String, ignoringPreference: Bool = false, in database: isolated BudgetDatabase) throws -> Set<String> {
        try database.queue.read { db in
            let preference = try SyncedPreferences.value(SyncedPreferenceKey("sync-reimport-deleted-\(accountID)"), in: database, db: db)
            let reimportDeleted = ignoringPreference ? "false" : (preference ?? "true")
            guard reimportDeleted != "true",
                  try database.tableExists("transactions", db: db) else { return [] }
            let columns = try database.columnSet(for: "transactions", db: db)
            let split = TransactionSplitQueryExpressions(columns: columns)
            guard split.tombstone != nil,
                  let financialID = TransactionRowColumns.importedID(in: columns) else {
                return []
            }
            return try Set(String.fetchAll(db, sql: """
                SELECT DISTINCT t.\(financialID) FROM transactions t
                WHERE \(split.qualifiedAccount) = ?
                  AND \(split.internalViewPredicate)
                  AND NOT \(split.liveRowPredicate)
                  AND t.\(financialID) IS NOT NULL AND t.\(financialID) != ''
                """, arguments: [accountID]))
        }
    }

    /// loot-core `linkSimpleFinAccount`: point the local account at the
    /// SimpleFIN account id and find-or-create the `banks` row on
    /// `(bank_id, name)`. The bank's messages come first, as the bank row is
    /// inserted before the account update upstream.
    static func makeBankSyncLinkMessages(
        accountID: String,
        remote: SimpleFINRemoteAccount,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let bankID = remote.orgDomain ?? remote.orgID
        guard let bankID, !bankID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing SimpleFIN bank id")
        }
        let resolution = try findOrCreateBank(
            bankID: bankID,
            name: remote.orgName ?? remote.institution,
            makeID: {
                UUID().uuidString
            },
            builder: &builder,
            in: database
        )
        let bank = resolution.bank
        return try database.queue.read { db in
            let columns = try database.columnSet(for: "accounts", db: db)
            guard columns.contains("account_id"), columns.contains("account_sync_source"), columns.contains("bank") else {
                throw LocalFirstError.invalidLocalWrite("missing accounts link columns")
            }
            return resolution.messages + [
                try builder.makeMessage(dataset: "accounts", row: accountID, column: "account_id", value: .string(remote.accountID)),
                try builder.makeMessage(
                    dataset: "accounts",
                    row: accountID,
                    column: "account_sync_source",
                    value: .string(BankSyncLinkEligibility.simpleFINSource)
                ),
                try builder.makeMessage(dataset: "accounts", row: accountID, column: "bank", value: .string(bank.id))
            ]
        }
    }

    /// loot-core `unlinkAccount`: clear the web-visible link columns and
    /// leave transactions alone.
    static func makeBankSyncUnlinkMessages(
        accountID: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        try database.queue.read { db in
            try makeBankSyncUnlinkMessages(accountID: accountID, builder: &builder, in: database, db: db)
        }
    }

    static func makeBankSyncUnlinkMessages(
        accountID: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        let columns = try database.columnSet(for: "accounts", db: db)
        guard columns.contains("account_id"),
              columns.contains("account_sync_source"),
              let link = try Row.fetchOne(
                db,
                sql: "SELECT account_id, account_sync_source FROM accounts WHERE id = ? LIMIT 1",
                arguments: [accountID]
              ),
              let remoteAccountID = link["account_id"] as String?,
              !remoteAccountID.isEmpty,
              BankSyncLinkEligibility.isSimpleFIN(
                syncSource: link["account_sync_source"] as String?
              ) else {
            throw LocalFirstError.refusedChange(
                "Only SimpleFIN-linked accounts can be unlinked here."
            )
        }
        let clearedColumns = [
            "account_id",
            "bank",
            "balance_current",
            "balance_available",
            "balance_limit",
            "account_sync_source",
            "bank_sync_status"
        ].filter { columns.contains($0) }
        guard !clearedColumns.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing accounts link columns")
        }
        return try clearedColumns.map { columnName in
            try builder.makeMessage(
                dataset: "accounts",
                row: accountID,
                column: columnName,
                value: .null
            )
        }
    }
}
