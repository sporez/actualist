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
