import Foundation
import GRDB

extension BudgetDatabase {
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

    /// Whether the account has any live transaction at all (not window
    /// bounded). Drives the first-apply opening-balance decision.
    func bankSyncAccountHasLiveTransactions(accountID: String) throws -> Bool {
        try queue.read { db in
            guard try tableExists("transactions", db: db) else { return false }
            let columns = try columnSet(for: "transactions", db: db)
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM transactions
                    WHERE acct = ? AND \(predicateForLiveRows(columns: columns))
                    """,
                arguments: [accountID]
            ) != 0
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
            let payeeColumn = try firstExistingColumn(["description", "payee"], in: columns, table: "transactions")
            let financialIDColumn = ["financial_id", "imported_id"].first { columns.contains($0) }
            let importedPayeeColumn = ["imported_description", "imported_payee"].first { columns.contains($0) }
            let reconciledColumn = ["reconciled"].first { columns.contains($0) }
            let isParentColumn = columns.contains("is_parent") ? "is_parent" : (columns.contains("isParent") ? "isParent" : nil)
            let isChildColumn = columns.contains("is_child") ? "is_child" : (columns.contains("isChild") ? "isChild" : nil)
            let parentColumn = columns.contains("parent_id") ? "parent_id" : nil

            let sql = """
                SELECT id, \(financialIDColumn ?? "NULL") AS financial_id, date, amount,
                       \(payeeColumn) AS payee, category, \(columns.contains("notes") ? "notes" : "NULL") AS notes,
                       \(columns.contains("cleared") ? "cleared" : "NULL") AS cleared,
                       \(reconciledColumn ?? "NULL") AS reconciled,
                       \(importedPayeeColumn ?? "NULL") AS imported_payee,
                       \(isParentColumn ?? "NULL") AS is_parent,
                       \(isChildColumn ?? "NULL") AS is_child,
                       \(parentColumn ?? "NULL") AS parent_id
                FROM transactions
                WHERE acct = ? AND date BETWEEN \(window.lowerBound) AND \(window.upperBound)
                  AND \(predicateForLiveRows(columns: columns))
                """
            return try Row.fetchAll(db, sql: sql, arguments: [accountID]).compactMap { row in
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
                    categoryID: row["category"],
                    notes: row["notes"],
                    cleared: (row["cleared"] as Int? ?? 0) != 0,
                    reconciled: (row["reconciled"] as Int? ?? 0) != 0,
                    importedPayee: row["imported_payee"],
                    isParent: isParent,
                    isChild: isChild,
                    parentID: row["parent_id"]
                )
            }
        }
    }

    /// Resolve an existing payee by name, case-insensitive, without creating
    /// one (matching-phase contract). Transfer payees are never candidates.
    func bankSyncResolvedPayeeID(name: String) throws -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try fetchPayees().first(where: {
            $0.transferAccount == nil && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        })?.id
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
                try builder.makeMessage(dataset: "accounts", row: accountID, column: "account_sync_source", value: .string("simpleFin")),
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

    /// Post-apply stamping. `bank_sync_status` records the download outcome;
    /// `last_sync` moves only when the download itself succeeded, so a
    /// failed account keeps its previous sync time.
    func makeBankSyncStampMessages(
        accountID: String,
        lastSyncEpochMilliseconds: Int64?,
        status: ActualBankSyncDurableStatus,
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
            return messages
        }
    }

    /// One matched row's update messages. Only fields that actually change
    /// from the current row are written; the parent's planned cleared value
    /// cascades onto its live children in the same commit.
    func makeBankSyncMatchUpdateMessages(
        update: BankSyncReconciliation.MatchedUpdate,
        existing: BankSyncReconciliation.Existing,
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
            if columns.contains("category"), let categoryID = update.categoryID {
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
