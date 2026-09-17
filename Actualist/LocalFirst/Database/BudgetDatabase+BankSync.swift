import Foundation
import GRDB

extension BudgetDatabase {
    /// Closing/reimporting waits only for a synchronous bank commit already in
    /// progress. Retained handles cannot commit another result after close.
    nonisolated func invalidateBankSyncWrites() {
        bankSyncWritesAllowed.withLock { $0 = false }
    }

    func commitBankSyncMessages(
        _ messages: [ActualSyncDecodedMessage],
        expectedLink: BankSyncLinkIdentity
    ) throws -> Int {
        try bankSyncWritesAllowed.withLock { allowed in
            guard allowed else { throw LocalFirstError.budgetNotOpened }
            try Task.checkCancellation()
            return try commitLocalSyncMessagesAndEnqueue(messages, expectedBankLink: expectedLink)
        }
    }

    /// Called inside the same transaction as the import, status and outbox.
    func validateBankSyncLink(_ expected: BankSyncLinkIdentity?, db: Database) throws {
        guard let expected else { return }
        let storageID = try String.fetchOne(db,
            sql: "SELECT storage_id FROM actualist_budget_identity WHERE id = 1")
        let columns = try columnSet(for: "accounts", db: db)
        let closed = column("closed", fallback: "0", columns: columns)
        let matches = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM accounts
            WHERE id = ? AND account_id = ? AND account_sync_source = ?
              AND \(predicateForLiveRows(columns: columns)) AND COALESCE(\(closed), 0) = 0)
            """, arguments: [expected.accountID, expected.remoteAccountID, expected.syncSource]) ?? false
        guard storageID == expected.storageID, matches else {
            throw LocalFirstError.invalidLocalWrite("the bank link changed; download again")
        }
    }

    /// Open-time backfill for SimpleFIN bank sync. Imported budgets may lack
    /// the `banks` table and the account link columns that Actual's
    /// `linkSimpleFinAccount` writes. Creating them here keeps local CRDT
    /// writes (`validateLocalMessage`) from rejecting link/unlink messages on
    /// older imports. Mirrors the existing `bank_sync_status` backfill.
    static func prepareBankSyncSchemaCompatibility(in queue: DatabaseQueue) throws {
        try queue.write { db in
            let accountsTableExists = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM sqlite_master
                        WHERE type = 'table' AND name = 'accounts'
                    )
                    """
            ) ?? false

            if accountsTableExists {
                let accountColumns = try Set(
                    Row.fetchAll(db, sql: "PRAGMA table_info(accounts)")
                        .compactMap { $0["name"] as String? }
                )
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

            let banksTableExists = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM sqlite_master
                        WHERE type = 'table' AND name = 'banks'
                    )
                    """
            ) ?? false
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

    /// loot-core `findOrCreateBank`: match on **both** `bank_id` and `name`.
    /// The same `(bank_id, name)` pair reuses the row; the same `bank_id` with
    /// a different name creates a distinct bank row.
    func findOrCreateBank(
        bankID: String,
        name: String?,
        makeID: @Sendable () -> String
    ) throws -> BankSyncBankRow {
        try queue.write { db in
            let columns = try columnSet(for: "banks", db: db)
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

            if let existingRow,
               let id: String = existingRow["id"],
               let existingBankID: String = existingRow["bank_id"] {
                return BankSyncBankRow(
                    id: id,
                    bankID: existingBankID,
                    name: existingRow["name"]
                )
            }

            let id = makeID()
            try db.execute(
                sql: "INSERT INTO banks (id, bank_id, name) VALUES (?, ?, ?)",
                arguments: [id, bankID, name]
            )
            return BankSyncBankRow(id: id, bankID: bankID, name: name)
        }
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
    func bankSyncLinkedAccounts() throws -> [BankSyncLinkedAccount] {
        try queue.read { db in
            guard try tableExists("accounts", db: db) else { return [] }
            let columns = try columnSet(for: "accounts", db: db)
            guard columns.contains("account_id"), columns.contains("account_sync_source") else {
                return []
            }
            let offbudget = column("offbudget", fallback: "0", columns: columns)
            let lastSync = column("last_sync", fallback: "NULL", columns: columns)
            let status = column("bank_sync_status", fallback: "NULL", columns: columns)
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, \(offbudget) AS offbudget, account_id,
                           account_sync_source, \(lastSync) AS last_sync,
                           \(status) AS bank_sync_status
                    FROM accounts
                    WHERE \(predicateForLiveRows(columns: columns))
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

    /// Oldest live transaction day for the account (`YYYYMMDD`), for the
    /// sync lookback start. `nil` when the account has no live rows.
    func bankSyncOldestLiveTransactionDayID(accountID: String) throws -> String? {
        try queue.read { db in
            guard try tableExists("transactions", db: db) else { return nil }
            let columns = try columnSet(for: "transactions", db: db)
            let oldest: Int? = try Int.fetchOne(
                db,
                sql: """
                    SELECT MIN(date) FROM transactions
                    WHERE acct = ? AND \(predicateForLiveRows(columns: columns))
                    """,
                arguments: [accountID]
            )
            return oldest.map(String.init)
        }
    }

    /// Live rows in the match window with `v_transactions` semantics: valid
    /// split children included, tombstones and invalid `is_child` rows
    /// without a parent excluded. The window bound is month-widened by the
    /// caller; the reconciler applies the exact ±7-day filter.
    func bankSyncExistingRows(accountID: String, window: ClosedRange<Int>) throws -> [BankSyncReconciliation.Existing] {
        try queue.read { db in
            guard try tableExists("transactions", db: db) else { return [] }
            let columns = try columnSet(for: "transactions", db: db)
            let split = transactionSplitQueryExpressions(columns: columns)
            let financialIDColumn = ["financial_id", "imported_id"].first { columns.contains($0) }
            let importedPayeeColumn = ["imported_description", "imported_payee"].first { columns.contains($0) }
            let transferIDColumn = ["transferred_id", "transfer_id"].first { columns.contains($0) }
            let financialIDSelect = financialIDColumn.map { "t.\($0)" } ?? "NULL"
            let importedPayeeSelect = importedPayeeColumn.map { "t.\($0)" } ?? "NULL"
            let transferIDSelect = transferIDColumn.map { "t.\($0)" } ?? "NULL"

            let sql = """
                SELECT t.id AS id,
                       \(financialIDSelect) AS financial_id,
                       \(split.qualifiedDate) AS date,
                       \(split.qualifiedAmount) AS amount,
                       \(split.qualifiedPayee) AS payee,
                       \(split.qualifiedCategory) AS category,
                       \(split.qualifiedNotes) AS notes,
                       \(split.qualifiedCleared) AS cleared,
                       \(split.qualifiedReconciled) AS reconciled,
                       \(importedPayeeSelect) AS imported_payee,
                       \(split.qualifiedIsParent) AS is_parent,
                       \(split.qualifiedIsChild) AS is_child,
                       \(split.effectiveParentID) AS parent_id,
                       \(transferIDSelect) AS transfer_id
                FROM transactions t
                \(split.parentJoin())
                WHERE \(split.qualifiedAccount) = ?
                  AND \(split.qualifiedDate) BETWEEN ? AND ?
                  AND \(split.liveEffectivePredicate())
                """
            return try Row.fetchAll(
                db,
                sql: sql,
                arguments: [accountID, window.lowerBound, window.upperBound]
            ).compactMap { row in
                guard let id: String = row["id"],
                      let day: Int = row["date"] else {
                    return nil
                }
                let isParent = (row["is_parent"] as Int? ?? 0) != 0
                let isChild = (row["is_child"] as Int? ?? 0) != 0
                return BankSyncReconciliation.Existing(
                    id: id,
                    financialID: row["financial_id"],
                    dayID: String(day),
                    amountMinorUnits: row["amount"] as Int? ?? 0,
                    payeeID: row["payee"],
                    categoryID: isParent ? nil : row["category"],
                    notes: row["notes"],
                    cleared: (row["cleared"] as Int? ?? 0) != 0,
                    reconciled: (row["reconciled"] as Int? ?? 0) != 0,
                    importedPayee: row["imported_payee"],
                    isParent: isParent,
                    isChild: isChild,
                    parentID: isChild ? row["parent_id"] : nil,
                    transferID: (row["transfer_id"] as String?).flatMap { $0.isEmpty ? nil : $0 }
                )
            }
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

    func bankSyncImportPreferences(accountID: String) throws -> BankSyncImportPreferences {
        try queue.read { db in
            func flag(_ key: String) throws -> Bool {
                (try preferenceValue(key, db: db) ?? "true") == "true"
            }
            return BankSyncImportPreferences(
                importPending: try flag("sync-import-pending-\(accountID)"),
                importNotes: try flag("sync-import-notes-\(accountID)"),
                customMappingsJSON: try preferenceValue(
                    "custom-sync-mappings-\(accountID)",
                    db: db
                )
            )
        }
    }

    /// Actual 26.9.0 matchTransactions defaults a missing preference to true.
    /// Deleted IDs are account-wide dedupe keys, never mutable match rows.
    func bankSyncSuppressedFinancialIDs(accountID: String) throws -> Set<String> {
        try queue.read { db in
            let reimportDeleted = try preferenceValue("sync-reimport-deleted-\(accountID)", db: db) ?? "true"
            guard reimportDeleted != "true",
                  try tableExists("transactions", db: db) else { return [] }
            let columns = try columnSet(for: "transactions", db: db)
            let split = transactionSplitQueryExpressions(columns: columns)
            guard split.tombstone != nil,
                  let financialID = ["financial_id", "imported_id"].first(where: columns.contains) else {
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

    /// Income category for a starting-balance row. `nil` when the budget has
    /// no live income category; the opening balance then lands uncategorized.
    func bankSyncIncomeCategoryID() throws -> String? {
        try queue.read { db in
            guard try tableExists("categories", db: db) else { return nil }
            let columns = try columnSet(for: "categories", db: db)
            let order = columns.contains("sort_order") ? "sort_order" : "lower(name)"
            return try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM categories
                    WHERE is_income = 1 AND \(predicateForLiveRows(columns: columns))
                    ORDER BY \(order) LIMIT 1
                    """
            )
        }
    }

    // MARK: - Message builders (Phase 3)

    /// loot-core `linkSimpleFinAccount`: point the local account at the
    /// SimpleFIN account id and find-or-create the `banks` row on
    /// `(bank_id, name)`.
    func makeBankSyncLinkMessages(
        accountID: String,
        remote: SimpleFINRemoteAccount,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let bankID = remote.orgDomain ?? remote.orgID
        guard let bankID, !bankID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing SimpleFIN bank id")
        }
        let bank = try findOrCreateBank(
            bankID: bankID,
            name: remote.orgName ?? remote.institution
        ) {
            UUID().uuidString
        }
        return try queue.read { db in
            let columns = try columnSet(for: "accounts", db: db)
            guard columns.contains("account_id"), columns.contains("account_sync_source"), columns.contains("bank") else {
                throw LocalFirstError.invalidLocalWrite("missing accounts link columns")
            }
            return [
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
    func makeBankSyncUnlinkMessages(
        accountID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            let columns = try columnSet(for: "accounts", db: db)
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
                throw LocalFirstError.invalidLocalWrite(
                    "only SimpleFIN-linked accounts can be unlinked here"
                )
            }
            let clearedColumns = [
                "account_id",
                "account_sync_source",
                "bank",
                "balance_current",
                "balance_available",
                "balance_limit",
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

    /// Post-apply completion metadata. Successful downloads replace or clear
    /// current bank-balance evidence and advance `last_sync`; failed downloads
    /// preserve both while recording their status.
    func makeBankSyncCompletionMessages(
        accountID: String,
        lastSyncEpochMilliseconds: Int64?,
        status: ActualBankSyncDurableStatus,
        balanceDisposition: BankSyncReview.BalanceDisposition,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            let columns = try columnSet(for: "accounts", db: db)
            var messages: [ActualSyncDecodedMessage] = []
            if columns.contains("bank_sync_status") {
                messages.append(try builder.makeMessage(
                    dataset: "accounts",
                    row: accountID,
                    column: "bank_sync_status",
                    value: .string(status.rawValue)
                ))
            }
            if let lastSyncEpochMilliseconds, columns.contains("last_sync") {
                messages.append(try builder.makeMessage(
                    dataset: "accounts",
                    row: accountID,
                    column: "last_sync",
                    value: .string(String(lastSyncEpochMilliseconds))
                ))
            }
            if columns.contains("balance_current") {
                switch balanceDisposition {
                case .set(let minorUnits):
                    messages.append(try builder.makeMessage(
                        dataset: "accounts",
                        row: accountID,
                        column: "balance_current",
                        value: .int(Int64(minorUnits))
                    ))
                case .clear:
                    messages.append(try builder.makeMessage(
                        dataset: "accounts",
                        row: accountID,
                        column: "balance_current",
                        value: .null
                    ))
                case .preserve:
                    break
                }
            }
            return messages
        }
    }

    /// One matched row's update messages. Only fields that actually change
    /// from the current row are written; the parent's planned cleared value
    /// cascades onto its live children in the same commit.
    func makeBankSyncMatchUpdateMessages(
        update: BankSyncReconciliation.MatchedUpdate,
        existing: BankSyncReconciliation.Existing,
        accountIsOffBudget: Bool = false,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            let columns = try columnSet(for: "transactions", db: db)
            var messages: [ActualSyncDecodedMessage] = []

            func appendIfChanged(_ column: String, _ newValue: LocalFirstSyncValue, changed: Bool) throws {
                guard changed else { return }
                messages.append(try builder.makeMessage(
                    dataset: "transactions", row: update.existingID, column: column, value: newValue
                ))
            }

            if let financialIDColumn = ["financial_id", "imported_id"].first(where: columns.contains) {
                if let financialID = update.financialID {
                    try appendIfChanged(
                        financialIDColumn,
                        .string(financialID),
                        changed: financialID != existing.financialID
                    )
                }
            }
            let payeeColumn = try firstExistingColumn(["description", "payee"], in: columns, table: "transactions")
            if let payeeID = update.payeeID {
                try appendIfChanged(payeeColumn, .string(payeeID), changed: payeeID != existing.payeeID)
            }
            // Bank Sync never manufactures a category on a transfer or off-budget row.
            if columns.contains("category"),
               let categoryID = update.categoryID,
               !existing.isTransfer,
               !accountIsOffBudget {
                try appendIfChanged("category", .string(categoryID), changed: categoryID != existing.categoryID)
            }
            if let importedPayeeColumn = ["imported_description", "imported_payee"].first(where: columns.contains) {
                if let importedPayee = update.importedPayee {
                    try appendIfChanged(
                        importedPayeeColumn,
                        .string(importedPayee),
                        changed: importedPayee != existing.importedPayee
                    )
                }
            }
            if columns.contains("notes"), let notes = update.notes {
                try appendIfChanged("notes", .string(notes), changed: notes != existing.notes)
            }
            if columns.contains("cleared") {
                try appendIfChanged("cleared", .bool(update.cleared), changed: update.cleared != existing.cleared)
            }
            for childID in update.childIDs where columns.contains("cleared") {
                messages.append(try builder.makeMessage(
                    dataset: "transactions", row: childID, column: "cleared", value: .bool(update.cleared)
                ))
            }
            return messages
        }
    }

    /// Opening-balance row: Starting Balance payee, income category only for
    /// on-budget accounts, rules skipped (`applyRules: false`), and the
    /// `starting_balance_flag` marker when the schema carries it.
    func makeBankSyncOpeningBalanceMessages(
        transactionID: String,
        accountID: String,
        openingBalance: BankSyncReconciliation.OpeningBalance,
        onBudget: Bool,
        sortOrder: Double,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let (payeeID, payeeMessages) = try resolveOrCreatePayeeMessages(
            selectedPayeeID: nil,
            payeeName: "Starting Balance",
            builder: &builder
        )
        guard let date = BankSyncAmounts.date(fromDayID: openingBalance.dayID) else {
            throw LocalFirstError.invalidLocalWrite("invalid opening balance date")
        }
        let draft = TransactionDraft(
            accountID: accountID,
            date: date,
            amountMinorUnits: openingBalance.amountMinorUnits,
            payeeID: payeeID,
            payeeName: "Starting Balance",
            categoryID: onBudget ? try bankSyncIncomeCategoryID() : nil,
            notes: nil,
            cleared: true,
            isTransfer: false
        )
        let transactionMessages = try createSimpleTransactionMessages(
            draft,
            transactionID: transactionID,
            payeeID: payeeID,
            builder: &builder
        )
        let flagMessage: [ActualSyncDecodedMessage] = try queue.read { db in
            let columns = try columnSet(for: "transactions", db: db)
            guard columns.contains("starting_balance_flag") else { return [] }
            return [try builder.makeMessage(
                dataset: "transactions",
                row: transactionID,
                column: "starting_balance_flag",
                value: .int(1)
            )]
        }
        return payeeMessages + transactionMessages + flagMessage
    }
}
