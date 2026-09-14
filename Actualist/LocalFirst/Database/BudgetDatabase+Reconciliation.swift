import Foundation
import GRDB

extension BudgetDatabase {
    func accountReconciliationSnapshot(accountID: String) throws -> AccountReconciliationSnapshot {
        let requestedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        return try queue.read { db in
            guard !requestedAccountID.isEmpty,
                  try tableExists("accounts", db: db) else {
                return unavailableReconciliationSnapshot(
                    accountID: requestedAccountID,
                    reason: .missingAccountSchema
                )
            }

            let accountColumns = try columnSet(for: "accounts", db: db)
            guard accountColumns.isSuperset(of: ["id", "name"]) else {
                return unavailableReconciliationSnapshot(
                    accountID: requestedAccountID,
                    reason: .missingAccountSchema
                )
            }

            let accountRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT name,
                           \(column("balance_current", fallback: "NULL", columns: accountColumns)) AS balance_current,
                           \(column("last_reconciled", fallback: "NULL", columns: accountColumns)) AS last_reconciled
                    FROM accounts
                    WHERE id = ? AND \(predicateForLiveRows(columns: accountColumns))
                    LIMIT 1
                    """,
                arguments: [requestedAccountID]
            )
            guard let accountRow else {
                return unavailableReconciliationSnapshot(
                    accountID: requestedAccountID,
                    reason: .accountNotFound
                )
            }

            let accountName = accountRow["name"] as String? ?? ""
            guard accountColumns.contains("last_reconciled") else {
                return unavailableReconciliationSnapshot(
                    accountID: requestedAccountID,
                    accountName: accountName,
                    reason: .missingLastReconciledColumn
                )
            }
            guard try tableExists("transactions", db: db) else {
                return unavailableReconciliationSnapshot(
                    accountID: requestedAccountID,
                    accountName: accountName,
                    reason: .missingTransactionSchema
                )
            }

            let transactionColumns = try columnSet(for: "transactions", db: db)
            guard transactionColumns.contains("amount"),
                  transactionColumns.contains("cleared"),
                  transactionColumns.contains("reconciled"),
                  transactionColumns.contains("acct") || transactionColumns.contains("account") else {
                return unavailableReconciliationSnapshot(
                    accountID: requestedAccountID,
                    accountName: accountName,
                    reason: .missingTransactionSchema
                )
            }

            let split = transactionSplitQueryExpressions(columns: transactionColumns)
            let workingBalance = try reconciliationBalance(
                db: db,
                accountID: requestedAccountID,
                split: split,
                splitMode: .inline,
                clearedOnly: false
            )
            let clearedBalance = try reconciliationBalance(
                db: db,
                accountID: requestedAccountID,
                split: split,
                splitMode: .none,
                clearedOnly: true
            )

            return AccountReconciliationSnapshot(
                accountID: requestedAccountID,
                accountName: accountName,
                workingBalance: workingBalance,
                clearedBalance: clearedBalance,
                lastSyncedBalance: reconciliationInteger(accountRow["balance_current"]),
                lastReconciledMilliseconds: reconciliationInt64(accountRow["last_reconciled"]),
                capability: .available
            )
        }
    }

    func createReconciliationAdjustment(
        accountID: String,
        targetBalance: Int,
        now: Date,
        transactionID: String = UUID().uuidString
    ) throws -> AccountReconciliationDatabaseWrite {
        let snapshot = try requireReconciliationSnapshot(accountID: accountID)
        let calculation = AccountReconciliationCalculation(
            targetBalance: targetBalance,
            clearedBalance: snapshot.clearedBalance
        )
        guard let difference = calculation.difference else {
            throw AccountReconciliationCommandError.differenceOverflow
        }
        guard difference != 0 else {
            throw AccountReconciliationCommandError.alreadyBalanced
        }

        var draft = TransactionDraft(
            accountID: snapshot.accountID,
            date: now,
            amountMinorUnits: difference,
            payeeID: nil,
            payeeName: "",
            categoryID: nil,
            notes: "Reconciliation balance adjustment",
            cleared: true,
            isTransfer: false,
            sortOrder: now.timeIntervalSince1970 * 1_000
        )
        let preview = try previewRules(for: draft)
        if preview.deletesTransaction {
            return AccountReconciliationDatabaseWrite(
                changed: ChangedResources(accounts: [], months: [], transactions: []),
                committed: false
            )
        }
        draft = TransactionRulePreviewProjection.applying(preview, to: draft)

        var builder = LocalFirstSyncMessageBuilder()
        let write: TransactionWriteResult
        let graph: BudgetTransactionGraph
        if draft.isSplit {
            write = try createSplitFamilyWrite(
                draft: draft,
                parentTransactionID: transactionID,
                payeeID: draft.payeeID,
                builder: &builder
            )
            graph = .split(childIDs: write.affectedTransactionIDs.filter { $0 != transactionID })
        } else if let payeeID = draft.payeeID,
                  try reconciliationTransferDestination(payeeID: payeeID) != nil {
            let transfer = try createTransferTransactionMessages(
                draft: draft,
                sourceTransactionID: transactionID,
                payeeID: payeeID,
                builder: &builder
            )
            write = TransactionWriteResult(
                messages: transfer.messages,
                affectedAccountIDs: [draft.accountID, transfer.destinationAccountID],
                affectedTransactionIDs: [transactionID, transfer.pairedTransactionID]
            )
            graph = .transfer(pairedID: transfer.pairedTransactionID)
        } else {
            write = try reconciliationSimpleTransactionWrite(
                draft: draft,
                transactionID: transactionID,
                builder: &builder
            )
            graph = .simple
        }
        let affectedAccounts = Set(write.affectedAccountIDs + [snapshot.accountID, draft.accountID])
        let affectedTransactions = Set(write.affectedTransactionIDs + [transactionID])
        let learningIDs: Set<String> = !draft.isSplit && draft.categoryID != nil
            ? [transactionID]
            : []
        _ = try commitUserAction(
            write.messages,
            descriptor: .createTransaction(CreateTransactionDescriptor(
                month: draft.month.rawValue,
                amount: draft.amountMinorUnits,
                payeeName: nil,
                categoryID: draft.categoryID,
                primaryTransactionID: transactionID,
                transactionIDs: affectedTransactions.sorted(),
                graph: graph,
                createdPayeeID: nil
            )),
            source: .ui,
            learningTransactionIDs: learningIDs,
            now: now
        )
        return AccountReconciliationDatabaseWrite(
            changed: ChangedResources(
                accounts: affectedAccounts.sorted(),
                months: [draft.month.rawValue],
                transactions: affectedTransactions.sorted()
            ),
            committed: true
        )
    }

    func finishReconciliation(
        accountID: String,
        targetBalance: Int,
        now: Date
    ) throws -> AccountReconciliationDatabaseWrite {
        let snapshot = try requireReconciliationSnapshot(accountID: accountID)
        let calculation = AccountReconciliationCalculation(
            targetBalance: targetBalance,
            clearedBalance: snapshot.clearedBalance
        )
        guard calculation.difference != nil else {
            throw AccountReconciliationCommandError.differenceOverflow
        }
        guard calculation.canLockTransactions else {
            throw AccountReconciliationCommandError.balanceChanged
        }

        let rows = try reconciliationRows(
            accountID: snapshot.accountID,
            reconciled: false,
            clearedOnly: true
        )
        var builder = LocalFirstSyncMessageBuilder()
        var messages = try rows.map {
            try builder.makeMessage(
                dataset: "transactions",
                row: $0.id,
                column: "reconciled",
                value: .bool(true)
            )
        }
        messages.append(try lastReconciledMessage(
            accountID: snapshot.accountID,
            now: now,
            builder: &builder
        ))
        _ = try commitLocalSyncMessagesAndEnqueue(messages, now: now)
        return AccountReconciliationDatabaseWrite(
            changed: ChangedResources(
                accounts: [snapshot.accountID],
                months: Set(rows.map(\.month)).sorted(),
                transactions: rows.map(\.id).sorted()
            ),
            committed: true
        )
    }

    func exitReconciliation(
        accountID: String,
        now: Date
    ) throws -> AccountReconciliationDatabaseWrite {
        let snapshot = try requireReconciliationSnapshot(accountID: accountID)
        var builder = LocalFirstSyncMessageBuilder()
        let message = try lastReconciledMessage(
            accountID: snapshot.accountID,
            now: now,
            builder: &builder
        )
        _ = try commitLocalSyncMessagesAndEnqueue([message], now: now)
        return AccountReconciliationDatabaseWrite(
            changed: ChangedResources(
                accounts: [snapshot.accountID],
                months: [],
                transactions: []
            ),
            committed: true
        )
    }

    func unlockReconciledTransaction(
        accountID: String,
        transactionID: String,
        now: Date
    ) throws -> AccountReconciliationDatabaseWrite {
        let snapshot = try requireReconciliationSnapshot(accountID: accountID)
        let rows = try reconciliationFamilyRows(
            accountID: snapshot.accountID,
            transactionID: transactionID
        )
        guard !rows.isEmpty else {
            throw AccountReconciliationCommandError.transactionNotFound
        }
        let reconciledRows = rows.filter(\.reconciled)
        guard !reconciledRows.isEmpty else {
            return AccountReconciliationDatabaseWrite(
                changed: ChangedResources(accounts: [], months: [], transactions: []),
                committed: false
            )
        }

        var builder = LocalFirstSyncMessageBuilder()
        let messages = try reconciledRows.map {
            try builder.makeMessage(
                dataset: "transactions",
                row: $0.id,
                column: "reconciled",
                value: .bool(false)
            )
        }
        _ = try commitLocalSyncMessagesAndEnqueue(messages, now: now)
        return AccountReconciliationDatabaseWrite(
            changed: ChangedResources(
                accounts: [snapshot.accountID],
                months: Set(rows.map(\.month)).sorted(),
                transactions: reconciledRows.map(\.id).sorted()
            ),
            committed: true
        )
    }

    private struct ReconciliationRow {
        let id: String
        let month: String
        let reconciled: Bool
    }

    private func requireReconciliationSnapshot(
        accountID: String
    ) throws -> AccountReconciliationSnapshot {
        let snapshot = try accountReconciliationSnapshot(accountID: accountID)
        if case .unavailable(let reason) = snapshot.capability {
            throw AccountReconciliationCommandError.unavailable(reason)
        }
        return snapshot
    }

    private func reconciliationSimpleTransactionWrite(
        draft: TransactionDraft,
        transactionID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> TransactionWriteResult {
        try queue.read { db in
            let columns = try resolveTransactionRowColumns(db: db)
            if try tableExists("accounts", db: db),
               try !rowExists(table: "accounts", rowID: draft.accountID, db: db) {
                throw LocalFirstError.invalidLocalWrite("missing account")
            }
            if let categoryID = draft.categoryID,
               try tableExists("categories", db: db),
               try !rowExists(table: "categories", rowID: categoryID, db: db) {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }
            if let payeeID = draft.payeeID,
               try tableExists("payees", db: db),
               try !rowExists(table: "payees", rowID: payeeID, db: db) {
                throw LocalFirstError.invalidLocalWrite("missing payee")
            }
            let messages = try transactionRowMessages(
                rowID: transactionID,
                accountID: draft.accountID,
                dateValue: Self.actualDateValue(draft.date),
                amountMinorUnits: draft.amountMinorUnits,
                payeeID: draft.payeeID,
                categoryID: draft.categoryID,
                notes: draft.notes,
                cleared: draft.cleared,
                reconciled: false,
                isParent: false,
                parentID: nil,
                isChild: false,
                transferID: nil,
                sortOrder: draft.sortOrder,
                columns: columns,
                builder: &builder,
                scheduleID: draft.scheduleID
            )
            return TransactionWriteResult(
                messages: messages,
                affectedAccountIDs: [draft.accountID],
                affectedTransactionIDs: [transactionID]
            )
        }
    }

    private func reconciliationTransferDestination(payeeID: String) throws -> String? {
        try queue.read { db in
            try transferAccountID(ifPayee: payeeID, db: db)
        }
    }

    private func reconciliationRows(
        accountID: String,
        reconciled: Bool,
        clearedOnly: Bool
    ) throws -> [ReconciliationRow] {
        try queue.read { db in
            let columns = try columnSet(for: "transactions", db: db)
            let split = transactionSplitQueryExpressions(columns: columns)
            var conditions = [
                split.liveEffectivePredicate(),
                "\(split.qualifiedAccount) = ?",
                "\(split.qualifiedReconciled) = ?",
            ]
            if clearedOnly {
                conditions.append("\(split.qualifiedCleared) != 0")
            }
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT t.id, \(split.qualifiedDate) AS date,
                           \(split.qualifiedReconciled) AS reconciled
                    FROM transactions t
                    \(split.parentJoin())
                    WHERE \(conditions.joined(separator: " AND "))
                    """,
                arguments: [accountID, reconciled ? 1 : 0]
            ).compactMap(reconciliationRow)
        }
    }

    private func reconciliationFamilyRows(
        accountID: String,
        transactionID: String
    ) throws -> [ReconciliationRow] {
        let requestedID = transactionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedID.isEmpty else { return [] }
        return try queue.read { db in
            let columns = try columnSet(for: "transactions", db: db)
            let split = transactionSplitQueryExpressions(columns: columns)
            let target = try Row.fetchOne(
                db,
                sql: """
                    SELECT t.id, \(split.effectiveParentID) AS parent_id
                    FROM transactions t
                    \(split.parentJoin())
                    WHERE t.id = ?
                      AND \(split.qualifiedAccount) = ?
                      AND \(split.liveEffectivePredicate())
                    LIMIT 1
                    """,
                arguments: [requestedID, accountID]
            )
            guard let target else { return [] }
            let rootID = (target["parent_id"] as String?) ?? requestedID
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT t.id, \(split.qualifiedDate) AS date,
                           \(split.qualifiedReconciled) AS reconciled
                    FROM transactions t
                    \(split.parentJoin())
                    WHERE (t.id = ? OR \(split.effectiveParentID) = ?)
                      AND \(split.qualifiedAccount) = ?
                      AND \(split.liveEffectivePredicate())
                    """,
                arguments: [rootID, rootID, accountID]
            ).compactMap(reconciliationRow)
        }
    }

    private func reconciliationRow(_ row: Row) -> ReconciliationRow? {
        guard let id = row["id"] as String?,
              let packedDate = reconciliationInteger(row["date"]) else {
            return nil
        }
        return ReconciliationRow(
            id: id,
            month: String(format: "%04d-%02d", packedDate / 10_000, (packedDate / 100) % 100),
            reconciled: flexibleBool(row["reconciled"])
        )
    }

    private func lastReconciledMessage(
        accountID: String,
        now: Date,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> ActualSyncDecodedMessage {
        let milliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        return try builder.makeMessage(
            dataset: "accounts",
            row: accountID,
            column: "last_reconciled",
            value: .string(String(milliseconds))
        )
    }

    private func reconciliationBalance(
        db: Database,
        accountID: String,
        split: TransactionSplitQueryExpressions,
        splitMode: TransactionSplitQueryMode,
        clearedOnly: Bool
    ) throws -> Int {
        var conditions = [
            split.liveEffectivePredicate(),
            split.splitModePredicate(splitMode),
            "\(split.qualifiedAccount) = ?",
        ]
        if clearedOnly {
            conditions.append("\(split.qualifiedCleared) != 0")
        }
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT SUM(\(split.qualifiedAmount)) AS balance
                FROM transactions t
                \(split.parentJoin())
                WHERE \(conditions.joined(separator: " AND "))
                """,
            arguments: [accountID]
        )
        return reconciliationInteger(row?["balance"]) ?? 0
    }

    private func unavailableReconciliationSnapshot(
        accountID: String,
        accountName: String = "",
        reason: AccountReconciliationUnavailableReason
    ) -> AccountReconciliationSnapshot {
        AccountReconciliationSnapshot(
            accountID: accountID,
            accountName: accountName,
            workingBalance: 0,
            clearedBalance: 0,
            lastSyncedBalance: nil,
            lastReconciledMilliseconds: nil,
            capability: .unavailable(reason)
        )
    }

    private func reconciliationInteger(_ value: DatabaseValueConvertible?) -> Int? {
        reconciliationInt64(value).flatMap(Int.init(exactly:))
    }

    private func reconciliationInt64(_ value: DatabaseValueConvertible?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Double, value.isFinite { return Int64(exactly: value) }
        if let value = value as? String { return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
}
