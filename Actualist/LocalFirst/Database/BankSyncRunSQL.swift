import Foundation
import GRDB

enum BankSyncRunSQL {
    static func commitBankSyncMessages(
        _ messages: [ActualSyncDecodedMessage],
        expectedLink: BankSyncLinkIdentity,
        pendingNewTransactions: BudgetDatabase.PendingNewTransactionCommit? = nil,
        expectedAbsentImportedIDs: BudgetDatabase.ImportedIDAbsence? = nil,
        expectedMatchedRows: BudgetDatabase.MatchedRowsUnchanged? = nil,
        in database: isolated BudgetDatabase
    ) throws -> Int {
        try Task.checkCancellation()
        return try database.commitLocalSyncMessagesAndEnqueue(
            messages,
            expectedBankLink: expectedLink,
            pendingNewTransactions: pendingNewTransactions,
            expectedAbsentImportedIDs: expectedAbsentImportedIDs,
            expectedMatchedRows: expectedMatchedRows
        )
    }

    /// Post-apply completion metadata. Successful downloads replace or clear
    /// current bank-balance evidence and advance `last_sync`; failed downloads
    /// preserve both while recording their status.
    static func makeBankSyncCompletionMessages(
        accountID: String,
        lastSyncEpochMilliseconds: Int64?,
        status: ActualBankSyncDurableStatus,
        balanceDisposition: BankSyncReview.BalanceDisposition,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        try database.queue.read { db in
            let columns = try database.columnSet(for: "accounts", db: db)
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

    /// Income category for a starting-balance row: the one named Starting
    /// Balances, else the first income category (`getStartingBalancePayee`,
    /// accounts/payees.ts). `nil` when the budget has no live income category.
    private static func bankSyncIncomeCategoryID(in database: isolated BudgetDatabase) throws -> String? {
        try database.queue.read { db in
            guard try database.tableExists("categories", db: db) else { return nil }
            let columns = try database.columnSet(for: "categories", db: db)
            let order = columns.contains("sort_order") ? "sort_order" : "lower(name)"
            return try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM categories
                    WHERE is_income = 1 AND \(database.predicateForLiveRows(columns: columns))
                    ORDER BY lower(name) = 'starting balances' DESC, \(order) LIMIT 1
                    """
            )
        }
    }

    // MARK: - Message builders (Phase 3)

    /// Opening-balance row: Starting Balance payee, income category only for
    /// on-budget accounts, rules skipped (`applyRules: false`), and the
    /// `starting_balance_flag` marker when the schema carries it.
    static func makeBankSyncOpeningBalanceMessages(
        transactionID: String,
        accountID: String,
        openingBalance: BankSyncReconciliation.OpeningBalance,
        onBudget: Bool,
        sortOrder: Double,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let (payeeID, payeeMessages) = try database.resolveOrCreatePayeeMessages(
            selectedPayeeID: nil,
            payeeName: "Starting Balance",
            builder: &builder
        )
        guard let date = BankSyncAmounts.date(fromDayID: openingBalance.dayID) else {
            throw LocalFirstError.invalidLocalWrite("invalid opening balance date")
        }
        var draft = TransactionDraft(
            accountID: accountID,
            date: date,
            amountMinorUnits: openingBalance.amountMinorUnits,
            payeeID: payeeID,
            payeeName: "Starting Balance",
            categoryID: onBudget ? try bankSyncIncomeCategoryID(in: database) : nil,
            notes: nil,
            cleared: true,
            isTransfer: false
        )
        draft.sortOrder = sortOrder
        let transactionMessages = try database.createSimpleTransactionMessages(
            draft,
            transactionID: transactionID,
            payeeID: payeeID,
            builder: &builder
        )
        let flagMessage: [ActualSyncDecodedMessage] = try database.queue.read { db in
            let columns = try database.columnSet(for: "transactions", db: db)
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

    /// Device-local record of the last finished Bank Sync run. The `actualist_`
    /// table is never part of CRDT sync, so the record stays on this device and
    /// with this budget.
    static func bankSyncLastRun(in database: isolated BudgetDatabase) throws -> BankSyncLastRun? {
        try database.queue.read { db in
            guard try database.tableExists("actualist_bank_sync_last_run", db: db),
                  let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM actualist_bank_sync_last_run WHERE id = 1"
                  ),
                  let finishedAt = row["finished_at"] as Double?,
                  let trigger = (row["trigger"] as String?).flatMap(BankSyncLastRun.Trigger.init(rawValue:)),
                  let summary = row["summary"] as String? else {
                return nil
            }
            return BankSyncLastRun(
                finishedAt: Date(timeIntervalSince1970: finishedAt),
                trigger: trigger,
                summary: summary,
                // A table written before this column existed has no `failure` value.
                failure: (row["failure"] as String?).flatMap(BankSyncWholeRequestFailure.init(rawValue:))
            )
        }
    }

    static func saveBankSyncLastRun(_ run: BankSyncLastRun, in database: isolated BudgetDatabase) throws {
        try database.queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS actualist_bank_sync_last_run (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    finished_at REAL NOT NULL,
                    trigger TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    failure TEXT
                )
                """)
            if try !db.columns(in: "actualist_bank_sync_last_run").contains(where: { $0.name == "failure" }) {
                try db.execute(sql: "ALTER TABLE actualist_bank_sync_last_run ADD COLUMN failure TEXT")
            }
            // Invalidate the cached miss. Caching true here would survive a transaction rollback.
            database.tableExistsCache["actualist_bank_sync_last_run"] = nil
            try db.execute(
                sql: """
                    INSERT INTO actualist_bank_sync_last_run (id, finished_at, trigger, summary, failure)
                    VALUES (1, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        finished_at = excluded.finished_at,
                        trigger = excluded.trigger,
                        summary = excluded.summary,
                        failure = excluded.failure
                    """,
                arguments: [run.finishedAt.timeIntervalSince1970, run.trigger.rawValue, run.summary, run.failure?.rawValue]
            )
        }
    }
}
